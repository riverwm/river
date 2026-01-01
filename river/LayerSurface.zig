// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

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
const SlotMap = @import("slotmap").SlotMap;
const XdgPopup = @import("XdgPopup.zig");

const log = std.log.scoped(.wm);

/// Only packed in order to make == work.
pub const Ref = packed struct {
    key: SlotMap(*LayerSurface).Key,

    pub fn get(ref: Ref) ?*LayerSurface {
        return server.layer_shell.surfaces.get(ref.key);
    }
};

ref: Ref,

wlr_layer_surface: *wlr.LayerSurfaceV1,
scene_layer_surface: *wlr.SceneLayerSurfaceV1,
popup_tree: *wlr.SceneTree,

destroy: wl.Listener(*wlr.LayerSurfaceV1) = wl.Listener(*wlr.LayerSurfaceV1).init(handleDestroy),
map: wl.Listener(void) = wl.Listener(void).init(handleMap),
unmap: wl.Listener(void) = wl.Listener(void).init(handleUnmap),
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),
new_popup: wl.Listener(*wlr.XdgPopup) = wl.Listener(*wlr.XdgPopup).init(handleNewPopup),

pub fn create(wlr_layer_surface: *wlr.LayerSurfaceV1) error{OutOfMemory}!void {
    const layer_surface = try util.gpa.create(LayerSurface);
    errdefer util.gpa.destroy(layer_surface);

    const key = try server.layer_shell.surfaces.put(util.gpa, layer_surface);
    errdefer server.layer_shell.surfaces.remove(key);

    const layer_tree = server.scene.layerSurfaceTree(wlr_layer_surface.current.layer);

    layer_surface.* = .{
        .ref = .{ .key = key },
        .wlr_layer_surface = wlr_layer_surface,
        .scene_layer_surface = try layer_tree.createSceneLayerSurfaceV1(wlr_layer_surface),
        .popup_tree = try server.scene.layers.popups.createSceneTree(),
    };

    try SceneNodeData.attach(&layer_surface.scene_layer_surface.tree.node, .{ .layer_surface = layer_surface });
    try SceneNodeData.attach(&layer_surface.popup_tree.node, .{ .layer_surface = layer_surface });

    wlr_layer_surface.surface.data = &layer_surface.scene_layer_surface.tree.node;

    wlr_layer_surface.events.destroy.add(&layer_surface.destroy);
    wlr_layer_surface.surface.events.map.add(&layer_surface.map);
    wlr_layer_surface.surface.events.unmap.add(&layer_surface.unmap);
    wlr_layer_surface.surface.events.commit.add(&layer_surface.commit);
    wlr_layer_surface.events.new_popup.add(&layer_surface.new_popup);
}

pub fn destroyPopups(layer_surface: *LayerSurface) void {
    var it = layer_surface.wlr_layer_surface.popups.safeIterator(.forward);
    while (it.next()) |wlr_xdg_popup| wlr_xdg_popup.destroy();
}

fn handleDestroy(listener: *wl.Listener(*wlr.LayerSurfaceV1), _: *wlr.LayerSurfaceV1) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("destroy", listener);

    log.debug("layer surface '{s}' destroyed", .{layer_surface.wlr_layer_surface.namespace});

    layer_surface.destroy.link.remove();
    layer_surface.map.link.remove();
    layer_surface.unmap.link.remove();
    layer_surface.commit.link.remove();
    layer_surface.new_popup.link.remove();

    layer_surface.destroyPopups();

    layer_surface.popup_tree.node.destroy();

    // The wlr_surface may outlive the wlr_layer_surface so we must clean up the user data.
    layer_surface.wlr_layer_surface.surface.data = null;

    server.layer_shell.surfaces.remove(layer_surface.ref.key);
    util.gpa.destroy(layer_surface);
}

fn handleMap(listener: *wl.Listener(void)) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("map", listener);
    const wlr_layer_surface = layer_surface.wlr_layer_surface;

    log.debug("layer surface '{s}' mapped", .{wlr_layer_surface.namespace});

    if (wlr_layer_surface.current.keyboard_interactive == .on_demand) {
        var it = server.input_manager.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.layer_shell.scheduled.focus != .exclusive) {
                seat.layer_shell.scheduled.focus = .{ .non_exclusive = layer_surface.ref };
            }
        }
    }

    // Beware: it is possible for arrange() to destroy this LayerSurface!
    const output: *Output = @ptrCast(@alignCast(layer_surface.wlr_layer_surface.output.?.data));
    output.layer_shell.arrange();
    server.layer_shell.updateFocus();
    server.wm.dirtyWindowing();
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("unmap", listener);

    log.debug("layer surface '{s}' unmapped", .{layer_surface.wlr_layer_surface.namespace});

    {
        var it = server.input_manager.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.focused == .layer_surface and seat.focused.layer_surface == layer_surface) {
                seat.focus(.none);
            }
        }
    }

    // Beware: it is possible for arrange() to destroy this LayerSurface!
    const output: *Output = @ptrCast(@alignCast(layer_surface.wlr_layer_surface.output.?.data));
    output.layer_shell.arrange();
    server.layer_shell.updateFocus();
    server.wm.dirtyWindowing();
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("commit", listener);
    const wlr_layer_surface = layer_surface.wlr_layer_surface;

    assert(wlr_layer_surface.output != null);

    // If the layer was changed, move the LayerSurface to the proper tree.
    if (wlr_layer_surface.current.committed.layer) {
        const tree = server.scene.layerSurfaceTree(wlr_layer_surface.current.layer);
        layer_surface.scene_layer_surface.tree.node.reparent(tree);
    }

    if (wlr_layer_surface.initial_commit or
        @as(u32, @bitCast(wlr_layer_surface.current.committed)) != 0)
    {
        // Beware: it is possible for arrange() to destroy this LayerSurface!
        const output: *Output = @ptrCast(@alignCast(layer_surface.wlr_layer_surface.output.?.data));
        output.layer_shell.arrange();
        server.layer_shell.updateFocus();
        server.wm.dirtyWindowing();
    }
}

fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("new_popup", listener);

    XdgPopup.create(
        wlr_xdg_popup,
        layer_surface.popup_tree,
        layer_surface.popup_tree,
    ) catch {
        wlr_xdg_popup.resource.postNoMemory();
        return;
    };
}
