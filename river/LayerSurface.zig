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

const log = std.log.scoped(.layer_shell);

output: *Output,
scene_layer_surface: *wlr.SceneLayerSurfaceV1,

destroy: wl.Listener(*wlr.LayerSurfaceV1) = wl.Listener(*wlr.LayerSurfaceV1).init(handleDestroy),
map: wl.Listener(*wlr.LayerSurfaceV1) = wl.Listener(*wlr.LayerSurfaceV1).init(handleMap),
unmap: wl.Listener(*wlr.LayerSurfaceV1) = wl.Listener(*wlr.LayerSurfaceV1).init(handleUnmap),
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),

pub fn create(wlr_layer_surface: *wlr.LayerSurfaceV1) error{OutOfMemory}!void {
    const output = @intToPtr(*Output, wlr_layer_surface.output.?.data);
    const layer_surface = try util.gpa.create(LayerSurface);
    errdefer util.gpa.destroy(layer_surface);

    const tree = output.layerSurfaceTree(wlr_layer_surface.current.layer);
    const scene_layer_surface = try tree.createSceneLayerSurfaceV1(wlr_layer_surface);

    try SceneNodeData.attach(&scene_layer_surface.tree.node, .{ .layer_surface = layer_surface });

    layer_surface.* = .{
        .output = output,
        .scene_layer_surface = scene_layer_surface,
    };
    wlr_layer_surface.data = @ptrToInt(layer_surface);

    wlr_layer_surface.events.destroy.add(&layer_surface.destroy);
    wlr_layer_surface.events.map.add(&layer_surface.map);
    wlr_layer_surface.events.unmap.add(&layer_surface.unmap);
    wlr_layer_surface.surface.events.commit.add(&layer_surface.commit);

    // wlroots only informs us of the new surface after the first commit,
    // so our listener does not get called for this first commit. However,
    // we do want our listener called in order to send the initial configure.
    handleCommit(&layer_surface.commit, wlr_layer_surface.surface);
}

fn handleDestroy(listener: *wl.Listener(*wlr.LayerSurfaceV1), wlr_layer_surface: *wlr.LayerSurfaceV1) void {
    const layer_surface = @fieldParentPtr(LayerSurface, "destroy", listener);

    log.debug("layer surface '{s}' destroyed", .{wlr_layer_surface.namespace});

    layer_surface.destroy.link.remove();
    layer_surface.map.link.remove();
    layer_surface.unmap.link.remove();
    layer_surface.commit.link.remove();

    util.gpa.destroy(layer_surface);
}

fn handleMap(listener: *wl.Listener(*wlr.LayerSurfaceV1), wlr_layer_surface: *wlr.LayerSurfaceV1) void {
    const layer_surface = @fieldParentPtr(LayerSurface, "map", listener);

    log.debug("layer surface '{s}' mapped", .{wlr_layer_surface.namespace});

    layer_surface.output.arrangeLayers();
    handleKeyboardInteractiveExclusive(layer_surface.output);
    server.root.startTransaction();
}

fn handleUnmap(listener: *wl.Listener(*wlr.LayerSurfaceV1), wlr_layer_surface: *wlr.LayerSurfaceV1) void {
    const layer_surface = @fieldParentPtr(LayerSurface, "unmap", listener);

    log.debug("layer surface '{s}' unmapped", .{wlr_layer_surface.namespace});

    layer_surface.output.arrangeLayers();
    handleKeyboardInteractiveExclusive(layer_surface.output);
    server.root.startTransaction();
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const layer_surface = @fieldParentPtr(LayerSurface, "commit", listener);
    const wlr_layer_surface = layer_surface.scene_layer_surface.layer_surface;

    assert(wlr_layer_surface.output != null);

    // If the layer was changed, move the LayerSurface to the proper tree.
    if (wlr_layer_surface.current.committed.layer) {
        const tree = layer_surface.output.layerSurfaceTree(wlr_layer_surface.current.layer);
        layer_surface.scene_layer_surface.tree.node.reparent(tree);
    }

    // If a surface is committed while it is not mapped, we must send a configure.
    if (!wlr_layer_surface.mapped or @bitCast(u32, wlr_layer_surface.current.committed) != 0) {
        layer_surface.output.arrangeLayers();
        handleKeyboardInteractiveExclusive(layer_surface.output);
        server.root.startTransaction();
    }
}

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
            if (@intToPtr(?*SceneNodeData, node.data)) |node_data| {
                const layer_surface = node_data.data.layer_surface;
                const wlr_layer_surface = layer_surface.scene_layer_surface.layer_surface;
                if (wlr_layer_surface.mapped and
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

        // Only grab focus of seats which have the output focused
        if (seat.focused_output != output) continue;

        if (topmost_surface) |to_focus| {
            // If we found a surface that requires focus, grab the focus of all
            // seats.
            seat.setFocusRaw(.{ .layer = to_focus });
        } else if (seat.focused == .layer) {
            const current_focus = seat.focused.layer.scene_layer_surface.layer_surface;
            // If the seat is currently focusing an unmapped layer surface or one
            // without keyboard interactivity, stop focusing that layer surface.
            if (!current_focus.mapped or current_focus.current.keyboard_interactive == .none) {
                seat.setFocusRaw(.{ .none = {} });
                seat.focus(null);
            }
        }
    }
}
