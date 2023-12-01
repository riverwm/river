// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const LayerSurface = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const zwlr = @import("wayland").server.zwlr;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const XdgPopup = @import("XdgPopup.zig");

const log = std.log.scoped(.layer_shell);

output: *Output,
wlr_layer_surface: *wlr.LayerSurfaceV1,
scene_layer_surface: *wlr.SceneLayerSurfaceV1,
popup_tree: *wlr.SceneTree,

destroy: wl.Listener(*wlr.LayerSurfaceV1) = wl.Listener(*wlr.LayerSurfaceV1).init(handleDestroy),
map: wl.Listener(void) = wl.Listener(void).init(handleMap),
unmap: wl.Listener(void) = wl.Listener(void).init(handleUnmap),
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),
new_popup: wl.Listener(*wlr.XdgPopup) = wl.Listener(*wlr.XdgPopup).init(handleNewPopup),

pub fn create(wlr_layer_surface: *wlr.LayerSurfaceV1) error{OutOfMemory}!void {
    const output: *Output = @ptrFromInt(wlr_layer_surface.output.?.data);
    const layer_surface = try util.gpa.create(LayerSurface);
    errdefer util.gpa.destroy(layer_surface);

    const layer_tree = output.layerSurfaceTree(wlr_layer_surface.current.layer);

    layer_surface.* = .{
        .output = output,
        .wlr_layer_surface = wlr_layer_surface,
        .scene_layer_surface = try layer_tree.createSceneLayerSurfaceV1(wlr_layer_surface),
        .popup_tree = try output.layers.popups.createSceneTree(),
    };
    wlr_layer_surface.data = @intFromPtr(layer_surface);

    try SceneNodeData.attach(&layer_surface.scene_layer_surface.tree.node, .{ .layer_surface = layer_surface });
    try SceneNodeData.attach(&layer_surface.popup_tree.node, .{ .layer_surface = layer_surface });

    wlr_layer_surface.surface.data = @intFromPtr(&layer_surface.scene_layer_surface.tree.node);

    wlr_layer_surface.events.destroy.add(&layer_surface.destroy);
    wlr_layer_surface.surface.events.map.add(&layer_surface.map);
    wlr_layer_surface.surface.events.unmap.add(&layer_surface.unmap);
    wlr_layer_surface.surface.events.commit.add(&layer_surface.commit);
    wlr_layer_surface.events.new_popup.add(&layer_surface.new_popup);

    // wlroots only informs us of the new surface after the first commit,
    // so our listener does not get called for this first commit. However,
    // we do want our listener called in order to send the initial configure.
    handleCommit(&layer_surface.commit, wlr_layer_surface.surface);
}

pub fn destroyPopups(layer_surface: *LayerSurface) void {
    var it = layer_surface.wlr_layer_surface.popups.safeIterator(.forward);
    while (it.next()) |wlr_xdg_popup| wlr_xdg_popup.destroy();
}

fn handleDestroy(listener: *wl.Listener(*wlr.LayerSurfaceV1), _: *wlr.LayerSurfaceV1) void {
    const layer_surface = @fieldParentPtr(LayerSurface, "destroy", listener);

    log.debug("layer surface '{s}' destroyed", .{layer_surface.wlr_layer_surface.namespace});

    layer_surface.destroy.link.remove();
    layer_surface.map.link.remove();
    layer_surface.unmap.link.remove();
    layer_surface.commit.link.remove();

    layer_surface.destroyPopups();

    layer_surface.popup_tree.node.destroy();

    util.gpa.destroy(layer_surface);
}

fn handleMap(listener: *wl.Listener(void)) void {
    const layer_surface = @fieldParentPtr(LayerSurface, "map", listener);

    log.debug("layer surface '{s}' mapped", .{layer_surface.wlr_layer_surface.namespace});

    layer_surface.output.arrangeLayers();
    handleKeyboardInteractiveExclusive(layer_surface.output);
    server.root.applyPending();
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const layer_surface = @fieldParentPtr(LayerSurface, "unmap", listener);

    log.debug("layer surface '{s}' unmapped", .{layer_surface.wlr_layer_surface.namespace});

    layer_surface.output.arrangeLayers();
    handleKeyboardInteractiveExclusive(layer_surface.output);
    server.root.applyPending();
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const layer_surface = @fieldParentPtr(LayerSurface, "commit", listener);
    const wlr_layer_surface = layer_surface.wlr_layer_surface;

    assert(wlr_layer_surface.output != null);

    // If the layer was changed, move the LayerSurface to the proper tree.
    if (wlr_layer_surface.current.committed.layer) {
        const tree = layer_surface.output.layerSurfaceTree(wlr_layer_surface.current.layer);
        layer_surface.scene_layer_surface.tree.node.reparent(tree);
    }

    if (wlr_layer_surface.initial_commit or
        @as(u32, @bitCast(wlr_layer_surface.current.committed)) != 0)
    {
        layer_surface.output.arrangeLayers();
        handleKeyboardInteractiveExclusive(layer_surface.output);
        server.root.applyPending();
    }
}

/// Requires a call to Root.applyPending()
fn handleKeyboardInteractiveExclusive(output: *Output) void {
    if (server.lock_manager.state != .unlocked) return;

    // Find the topmost layer surface in the top or overlay layers which
    // requests keyboard interactivity if any.
    const topmost_surface = outer: for ([_]zwlr.LayerShellV1.Layer{ .overlay, .top }) |layer| {
        const tree = output.layerSurfaceTree(layer);
        // Iterate in reverse to match rendering order.
        var it = tree.children.iterator(.reverse);
        while (it.next()) |node| {
            assert(node.type == .tree);
            if (@as(?*SceneNodeData, @ptrFromInt(node.data))) |node_data| {
                const layer_surface = node_data.data.layer_surface;
                const wlr_layer_surface = layer_surface.wlr_layer_surface;
                if (wlr_layer_surface.surface.mapped and
                    wlr_layer_surface.current.keyboard_interactive == .exclusive)
                {
                    break :outer layer_surface;
                }
            }
        }
    } else null;

    var it = server.input_manager.seats.first;
    while (it) |node| : (it = node.next) {
        const seat = &node.data;

        if (seat.focused_output == output) {
            if (topmost_surface) |to_focus| {
                // If we found a surface on the output that requires focus, grab the focus of all
                // seats that are focusing that output.
                seat.setFocusRaw(.{ .layer = to_focus });
                continue;
            }
        }

        if (seat.focused == .layer) {
            const current_focus = seat.focused.layer.wlr_layer_surface;
            // If the seat is currently focusing an unmapped layer surface or one
            // without keyboard interactivity, stop focusing that layer surface.
            if (!current_focus.surface.mapped or current_focus.current.keyboard_interactive == .none) {
                seat.setFocusRaw(.{ .none = {} });
            }
        }
    }
}

fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const layer_surface = @fieldParentPtr(LayerSurface, "new_popup", listener);

    XdgPopup.create(
        wlr_xdg_popup,
        layer_surface.popup_tree,
        layer_surface.popup_tree,
    ) catch {
        wlr_xdg_popup.resource.postNoMemory();
        return;
    };
}
