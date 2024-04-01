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

const InputMethodPopup = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const server = &@import("main.zig").server;

const util = @import("util.zig");
const InputRelay = @import("InputRelay.zig");
const TextInput = @import("TextInput.zig");
const Root = @import("Root.zig");
const View = @import("View.zig");
const LayerSurface = @import("LayerSurface.zig");
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandView = @import("XwaylandView.zig");

const log = std.log.scoped(.input_method_popup);

link: wl.list.Link,
scene_tree: ?*wlr.SceneTree = null,
parent_scene_tree: ?*wlr.SceneTree = null,
scene_surface: ?*wlr.SceneTree = null,
view: ?*View = null,

input_relay: *InputRelay,
wlr_input_popup_surface: *wlr.InputPopupSurfaceV2,

popup_surface_commit: wl.Listener(*wlr.Surface) =
    wl.Listener(*wlr.Surface).init(handlePopupSurfaceCommit),

popup_surface_map: wl.Listener(void) =
    wl.Listener(void).init(handlePopupSurfaceMap),

popup_surface_unmap: wl.Listener(void) =
    wl.Listener(void).init(handlePopupSurfaceUnmap),
popup_destroy: wl.Listener(void) =
    wl.Listener(void).init(handlePopupDestroy),

pub fn create(wlr_input_popup_surface: *wlr.InputPopupSurfaceV2, input_relay: *InputRelay) !void {
    const input_method_popup = try util.gpa.create(InputMethodPopup);
    errdefer util.gpa.destroy(input_method_popup);
    log.debug("new input_method_pupup", .{});
    input_method_popup.* = .{
        .link = undefined,
        .input_relay = input_relay,
        .wlr_input_popup_surface = wlr_input_popup_surface,
    };

    input_method_popup.wlr_input_popup_surface.events.destroy.add(&input_method_popup.popup_destroy);
    input_method_popup.wlr_input_popup_surface.surface.events.map.add(&input_method_popup.popup_surface_map);
    input_method_popup.wlr_input_popup_surface.surface.events.unmap.add(&input_method_popup.popup_surface_unmap);
    input_method_popup.wlr_input_popup_surface.surface.events.commit.add(&input_method_popup.popup_surface_commit);
    input_relay.input_method_popups.append(input_method_popup);
    input_method_popup.updatePopup();
}

fn handlePopupDestroy(listener: *wl.Listener(void)) void {
    log.debug("destroy ime_popup", .{});
    const input_method_popup = @fieldParentPtr(InputMethodPopup, "popup_destroy", listener);
    input_method_popup.popup_surface_map.link.remove();
    input_method_popup.popup_surface_unmap.link.remove();
    input_method_popup.popup_surface_commit.link.remove();
    input_method_popup.popup_destroy.link.remove();
    input_method_popup.link.remove();
    util.gpa.destroy(input_method_popup);
}

fn handlePopupSurfaceCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    log.debug("popup surface commit", .{});
    const input_method_popup = @fieldParentPtr(InputMethodPopup, "popup_surface_commit", listener);
    input_method_popup.updatePopup();
}

fn handlePopupSurfaceMap(listener: *wl.Listener(void)) void {
    log.debug("popup surface map", .{});
    const input_method_popup = @fieldParentPtr(InputMethodPopup, "popup_surface_map", listener);
    input_method_popup.updatePopup();
}

fn handlePopupSurfaceUnmap(listener: *wl.Listener(void)) void {
    log.debug("popup surface unmap", .{});
    const input_method_popup = @fieldParentPtr(InputMethodPopup, "popup_surface_unmap", listener);
    input_method_popup.scene_tree.?.node.destroy();
    input_method_popup.scene_tree = null;
}

pub fn updatePopup(input_method_popup: *InputMethodPopup) void {
    log.debug("update ime_popup", .{});
    var text_input = input_method_popup.getTextInputFocused() orelse return;
    const focused_surface = text_input.wlr_text_input.focused_surface orelse return;

    if (!input_method_popup.wlr_input_popup_surface.surface.mapped) {
        return;
    }

    var output_box: wlr.Box = undefined;
    var parent: wlr.Box = undefined;

    input_method_popup.getParentAndOutputBox(focused_surface, &parent, &output_box);

    var cursor_rect = if (text_input.wlr_text_input.current.features.cursor_rectangle)
        text_input.wlr_text_input.current.cursor_rectangle
    else
        wlr.Box{
            .x = 0,
            .y = 0,
            .width = parent.width,
            .height = parent.height,
        };

    const popup_width = input_method_popup.wlr_input_popup_surface.surface.current.width;
    const popup_height = input_method_popup.wlr_input_popup_surface.surface.current.height;

    const cursor_rect_left = parent.x + cursor_rect.x;
    const popup_anchor_left = blk: {
        const cursor_rect_right = cursor_rect_left + cursor_rect.width;
        const available_right_of_cursor = output_box.x + output_box.width - cursor_rect_left;
        const available_left_of_cursor = cursor_rect_right - output_box.x;
        if (available_right_of_cursor < popup_width and available_left_of_cursor > popup_width) {
            break :blk cursor_rect_right - popup_width;
        } else {
            break :blk cursor_rect_left;
        }
    };

    const cursor_rect_up = parent.y + cursor_rect.y;
    const popup_anchor_up = blk: {
        const cursor_rect_down = cursor_rect_up + cursor_rect.height;
        const available_down_of_cursor = output_box.y + output_box.height - cursor_rect_down;
        const available_up_of_cursor = cursor_rect_up - output_box.y;
        if (available_down_of_cursor < popup_height and available_up_of_cursor > popup_height) {
            break :blk cursor_rect_up - popup_height;
        } else {
            break :blk cursor_rect_down;
        }
    };

    if (text_input.wlr_text_input.current.features.cursor_rectangle) {
        var box = wlr.Box{
            .x = cursor_rect_left - popup_anchor_left,
            .y = cursor_rect_up - popup_anchor_up,
            .width = cursor_rect.width,
            .height = cursor_rect.height,
        };
        input_method_popup.wlr_input_popup_surface.sendTextInputRectangle(&box);
    }

    if (input_method_popup.scene_tree == null) {
        input_method_popup.scene_tree = input_method_popup.parent_scene_tree.?.createSceneTree() catch {
            log.err("out of memory", .{});
            return;
        };

        input_method_popup.scene_surface = input_method_popup.scene_tree.?
            .createSceneSubsurfaceTree(
            input_method_popup.wlr_input_popup_surface.surface,
        ) catch {
            log.err("failed to create subsurface tree", .{});
            input_method_popup.wlr_input_popup_surface.surface.resource.getClient().postNoMemory();
            return;
        };
    }
    input_method_popup.scene_tree.?.node.setPosition(popup_anchor_left - parent.x, popup_anchor_up - parent.y);
}

pub fn getTextInputFocused(input_method_popup: *InputMethodPopup) ?*TextInput {
    var it = input_method_popup.input_relay.text_inputs.iterator(.forward);
    while (it.next()) |text_input| {
        if (text_input.wlr_text_input.focused_surface != null) return text_input;
    }
    return null;
}

pub fn getParentAndOutputBox(
    input_method_popup: *InputMethodPopup,
    focused_surface: *wlr.Surface,
    parent: *wlr.Box,
    output_box: *wlr.Box,
) void {
    if (wlr.LayerSurfaceV1.tryFromWlrSurface(focused_surface)) |wlr_layer_surface| {
        const layer_surface: *LayerSurface = @ptrFromInt(wlr_layer_surface.data);
        input_method_popup.parent_scene_tree = layer_surface.popup_tree;
        const output = layer_surface.output.wlr_output;
        server.root.output_layout.getBox(output, output_box);
        _ = layer_surface.popup_tree.node.coords(&parent.x, &parent.y);
    } else {
        const view = getViewFromWlrSurface(focused_surface) orelse return;
        input_method_popup.parent_scene_tree = view.tree;
        _ = view.tree.node.coords(&parent.x, &parent.y);
        const output = view.current.output orelse return;
        server.root.output_layout.getBox(output.wlr_output, output_box);
        parent.width = view.current.box.width;
        parent.height = view.current.box.height;
    }
}

fn getViewFromWlrSurface(wlr_surface: *wlr.Surface) ?*View {
    if (wlr.XdgSurface.tryFromWlrSurface(wlr_surface)) |xdg_surface| {
        const xdg_toplevel: *XdgToplevel = @ptrFromInt(xdg_surface.data);
        return xdg_toplevel.view;
    }
    if (build_options.xwayland) {
        if (wlr.XwaylandSurface.tryFromWlrSurface(wlr_surface)) |xwayland_surface| {
            const xwayland_view: *XwaylandView = @ptrFromInt(xwayland_surface.data);
            return xwayland_view.view;
        }
    }
    if (wlr.Subsurface.tryFromWlrSurface(wlr_surface)) |wlr_subsurface| {
        if (wlr_subsurface.parent) |parent| return getViewFromWlrSurface(parent);
    }
    return null;
}
