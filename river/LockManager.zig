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

const LockManager = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const LockSurface = @import("LockSurface.zig");

locked: bool = false,
lock: ?*wlr.SessionLockV1 = null,

new_lock: wl.Listener(*wlr.SessionLockV1) = wl.Listener(*wlr.SessionLockV1).init(handleLock),
unlock: wl.Listener(void) = wl.Listener(void).init(handleUnlock),
destroy: wl.Listener(void) = wl.Listener(void).init(handleDestroy),
new_surface: wl.Listener(*wlr.SessionLockSurfaceV1) =
    wl.Listener(*wlr.SessionLockSurfaceV1).init(handleSurface),

pub fn init(manager: *LockManager) !void {
    manager.* = .{};
    const wlr_manager = try wlr.SessionLockManagerV1.create(server.wl_server);
    wlr_manager.events.new_lock.add(&manager.new_lock);
}

pub fn deinit(manager: *LockManager) void {
    // deinit() should only be called after wl.Server.destroyClients()
    assert(manager.lock == null);

    manager.new_lock.link.remove();
}

fn handleLock(listener: *wl.Listener(*wlr.SessionLockV1), lock: *wlr.SessionLockV1) void {
    const manager = @fieldParentPtr(LockManager, "new_lock", listener);

    if (manager.lock != null) {
        lock.destroy();
        return;
    }

    manager.lock = lock;
    lock.sendLocked();

    if (!manager.locked) {
        manager.locked = true;

        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) {
            const seat = &node.data;
            seat.setFocusRaw(.none);
            seat.cursor.updateState();

            // Enter locked mode
            seat.prev_mode_id = seat.mode_id;
            seat.enterMode(1);
        }
    }

    lock.events.new_surface.add(&manager.new_surface);
    lock.events.unlock.add(&manager.unlock);
    lock.events.destroy.add(&manager.destroy);
}

fn handleUnlock(listener: *wl.Listener(void)) void {
    const manager = @fieldParentPtr(LockManager, "unlock", listener);

    assert(manager.locked);
    manager.locked = false;

    {
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) {
            const seat = &node.data;
            seat.setFocusRaw(.none);
            seat.focus(null);
            seat.cursor.updateState();

            // Exit locked mode
            seat.enterMode(seat.prev_mode_id);
        }
    }

    handleDestroy(&manager.destroy);
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const manager = @fieldParentPtr(LockManager, "destroy", listener);

    manager.new_surface.link.remove();
    manager.unlock.link.remove();
    manager.destroy.link.remove();

    manager.lock = null;
}

fn handleSurface(
    listener: *wl.Listener(*wlr.SessionLockSurfaceV1),
    wlr_lock_surface: *wlr.SessionLockSurfaceV1,
) void {
    const manager = @fieldParentPtr(LockManager, "new_surface", listener);

    assert(manager.locked);
    assert(manager.lock != null);

    LockSurface.create(wlr_lock_surface, manager.lock.?);
}
