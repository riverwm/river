// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 The River Developers
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

const LockSurface = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const SceneNodeData = @import("SceneNodeData.zig");

wlr_lock_surface: *wlr.SessionLockSurfaceV1,
lock: *wlr.SessionLockV1,

idle_update_focus: ?*wl.EventSource = null,

map: wl.Listener(void) = .init(handleMap),
surface_destroy: wl.Listener(void) = .init(handleDestroy),

pub fn create(wlr_lock_surface: *wlr.SessionLockSurfaceV1, lock: *wlr.SessionLockV1) error{OutOfMemory}!void {
    const lock_surface = try util.gpa.create(LockSurface);
    errdefer util.gpa.destroy(lock_surface);

    lock_surface.* = .{
        .wlr_lock_surface = wlr_lock_surface,
        .lock = lock,
    };
    wlr_lock_surface.data = lock_surface;

    const tree = try server.scene.locked_tree.createSceneSubsurfaceTree(wlr_lock_surface.surface);
    errdefer tree.node.destroy();

    try SceneNodeData.attach(&tree.node, .{ .lock_surface = lock_surface });

    wlr_lock_surface.surface.data = &tree.node;

    wlr_lock_surface.surface.events.map.add(&lock_surface.map);
    wlr_lock_surface.events.destroy.add(&lock_surface.surface_destroy);

    lock_surface.configure();
}

pub fn destroy(lock_surface: *LockSurface) void {
    {
        var surface_it = lock_surface.lock.surfaces.iterator(.forward);
        const new_focus: Seat.Focus = while (surface_it.next()) |surface| {
            if (surface != lock_surface.wlr_lock_surface)
                break .{ .lock_surface = @ptrCast(@alignCast(surface.data)) };
        } else .none;

        var seat_it = server.input_manager.seats.iterator(.forward);
        while (seat_it.next()) |seat| {
            if (seat.focused == .lock_surface and seat.focused.lock_surface == lock_surface) {
                seat.focus(new_focus);
            }
            seat.cursor.updateState();
        }
    }

    if (lock_surface.idle_update_focus) |event_source| {
        event_source.remove();
    }

    lock_surface.map.link.remove();
    lock_surface.surface_destroy.link.remove();

    // The wlr_surface may outlive the wlr_lock_surface so we must clean up the user data.
    lock_surface.wlr_lock_surface.surface.data = null;

    util.gpa.destroy(lock_surface);
}

pub fn getOutput(lock_surface: *LockSurface) *Output {
    return @ptrCast(@alignCast(lock_surface.wlr_lock_surface.output.data));
}

pub fn configure(lock_surface: *LockSurface) void {
    var output_width: i32 = undefined;
    var output_height: i32 = undefined;
    lock_surface.wlr_lock_surface.output.effectiveResolution(&output_width, &output_height);
    _ = lock_surface.wlr_lock_surface.configure(@intCast(output_width), @intCast(output_height));
}

fn handleMap(listener: *wl.Listener(void)) void {
    const lock_surface: *LockSurface = @fieldParentPtr("map", listener);

    // Unfortunately the surface commit handlers for the scene subsurface tree corresponding to
    // this lock surface won't be called until after this function returns, which means that we cannot
    // update pointer focus yet as the nodes in the scene graph representing this lock surface are still
    // 0x0 in size. To work around this, use an idle callback.
    const event_loop = server.wl_server.getEventLoop();
    assert(lock_surface.idle_update_focus == null);
    lock_surface.idle_update_focus = event_loop.addIdle(*LockSurface, updateFocus, lock_surface) catch {
        std.log.err("out of memory", .{});
        return;
    };
}

fn updateFocus(lock_surface: *LockSurface) void {
    var it = server.input_manager.seats.iterator(.forward);
    while (it.next()) |seat| {
        if (seat.focused != .lock_surface) {
            seat.focus(.{ .lock_surface = lock_surface });
        }
        seat.cursor.updateState();
    }

    lock_surface.idle_update_focus = null;
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const lock_surface: *LockSurface = @fieldParentPtr("surface_destroy", listener);

    lock_surface.destroy();
}
