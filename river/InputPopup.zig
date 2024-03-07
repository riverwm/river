// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2024 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const InputPopup = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const InputRelay = @import("InputRelay.zig");
const SceneNodeData = @import("SceneNodeData.zig");

link: wl.list.Link,
input_relay: *InputRelay,

wlr_popup: *wlr.InputPopupSurfaceV2,
surface_tree: *wlr.SceneTree,

destroy: wl.Listener(void) = wl.Listener(void).init(handleDestroy),
map: wl.Listener(void) = wl.Listener(void).init(handleMap),
unmap: wl.Listener(void) = wl.Listener(void).init(handleUnmap),
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),

pub fn create(wlr_popup: *wlr.InputPopupSurfaceV2, input_relay: *InputRelay) !void {
    const input_popup = try util.gpa.create(InputPopup);
    errdefer util.gpa.destroy(input_popup);

    input_popup.* = .{
        .link = undefined,
        .input_relay = input_relay,
        .wlr_popup = wlr_popup,
        .surface_tree = try server.root.hidden.tree.createSceneSubsurfaceTree(wlr_popup.surface),
    };

    input_relay.input_popups.append(input_popup);

    input_popup.wlr_popup.events.destroy.add(&input_popup.destroy);
    input_popup.wlr_popup.surface.events.map.add(&input_popup.map);
    input_popup.wlr_popup.surface.events.unmap.add(&input_popup.unmap);
    input_popup.wlr_popup.surface.events.commit.add(&input_popup.commit);

    input_popup.update();
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const input_popup: *InputPopup = @fieldParentPtr("destroy", listener);

    input_popup.destroy.link.remove();
    input_popup.map.link.remove();
    input_popup.unmap.link.remove();
    input_popup.commit.link.remove();

    input_popup.link.remove();

    util.gpa.destroy(input_popup);
}

fn handleMap(listener: *wl.Listener(void)) void {
    const input_popup: *InputPopup = @fieldParentPtr("map", listener);

    input_popup.update();
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const input_popup: *InputPopup = @fieldParentPtr("unmap", listener);

    input_popup.surface_tree.node.reparent(server.root.hidden.tree);
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const input_popup: *InputPopup = @fieldParentPtr("commit", listener);

    input_popup.update();
}

pub fn update(input_popup: *InputPopup) void {
    const text_input = input_popup.input_relay.text_input orelse {
        input_popup.surface_tree.node.reparent(server.root.hidden.tree);
        return;
    };

    if (!input_popup.wlr_popup.surface.mapped) return;

    // This seems like it could be null if the focused surface is destroyed
    const focused_surface = text_input.wlr_text_input.focused_surface orelse return;

    // Focus should never be sent to subsurfaces
    assert(focused_surface.getRootSurface() == focused_surface);

    const focused = SceneNodeData.fromSurface(focused_surface) orelse return;

    const output = switch (focused.data) {
        .view => |view| view.current.output orelse return,
        .layer_surface => |layer_surface| layer_surface.output,
        .lock_surface => |lock_surface| lock_surface.getOutput(),
        // Xwayland doesn't use the text-input protocol
        .override_redirect => unreachable,
    };

    const popup_tree = switch (focused.data) {
        .view => |view| view.popup_tree,
        .layer_surface => |layer_surface| layer_surface.popup_tree,
        .lock_surface => |lock_surface| lock_surface.getOutput().layers.popups,
        // Xwayland doesn't use the text-input protocol
        .override_redirect => unreachable,
    };

    input_popup.surface_tree.node.reparent(popup_tree);

    if (!text_input.wlr_text_input.current.features.cursor_rectangle) {
        // If the text-input client does not inform us where in the surface
        // the active text input is there's not much we can do. Placing the
        // popup at the top left corner of the window is nice and simple
        // while not looking terrible.
        input_popup.surface_tree.node.setPosition(0, 0);
        return;
    }

    var focused_x: c_int = undefined;
    var focused_y: c_int = undefined;
    _ = focused.node.coords(&focused_x, &focused_y);

    var output_box: wlr.Box = undefined;
    server.root.output_layout.getBox(output.wlr_output, &output_box);

    // Relative to the surface with the active text input
    var cursor_box = text_input.wlr_text_input.current.cursor_rectangle;

    // Adjust to be relative to the output
    cursor_box.x += focused_x - output_box.x;
    cursor_box.y += focused_y - output_box.y;

    // Choose popup x/y relative to the output:

    // Align the left edge of the popup with the left edge of the cursor.
    // If the popup wouldn't fit on the output instead align the right edge
    // of the popup with the right edge of the cursor.
    const popup_x = blk: {
        const popup_width = input_popup.wlr_popup.surface.current.width;
        if (output_box.width - cursor_box.x >= popup_width) {
            break :blk cursor_box.x;
        } else {
            break :blk cursor_box.x + cursor_box.width - popup_width;
        }
    };

    // Align the top edge of the popup with the bottom edge of the cursor.
    // If the popup wouldn't fit on the output instead align the bottom edge
    // of the popup with the top edge of the cursor.
    const popup_y = blk: {
        const popup_height = input_popup.wlr_popup.surface.current.height;
        if (output_box.height - (cursor_box.y + cursor_box.height) >= popup_height) {
            break :blk cursor_box.y + cursor_box.height;
        } else {
            break :blk cursor_box.y - popup_height;
        }
    };

    // Scene node position is relative to the parent so adjust popup x/y to
    // be relative to the focused surface.
    input_popup.surface_tree.node.setPosition(
        popup_x - focused_x + output_box.x,
        popup_y - focused_y + output_box.y,
    );

    // The text input rectangle sent to the input method is relative to the popup.
    cursor_box.x -= popup_x;
    cursor_box.y -= popup_y;
    input_popup.wlr_popup.sendTextInputRectangle(&cursor_box);
}
