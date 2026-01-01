// SPDX-FileCopyrightText: © 2021 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const LockManager = @This();

const std = @import("std");
const assert = std.debug.assert;

const build_options = @import("build_options");

const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const LockSurface = @import("LockSurface.zig");
const Output = @import("Output.zig");

const log = std.log.scoped(.lock);

wlr_manager: *wlr.SessionLockManagerV1,

state: enum {
    /// No lock request has been made and the session is unlocked.
    unlocked,
    /// A lock request has been made and river is waiting for all outputs to have
    /// rendered a lock surface before sending the locked event.
    waiting_for_lock_surfaces,
    /// A lock request has been made but waiting for a lock surface to be rendered
    /// on all outputs timed out. Now river is waiting only for all outputs to at
    /// least be blanked before sending the locked event.
    waiting_for_blank,
    /// All outputs are either blanked or have a lock surface rendered and the
    /// locked event has been sent.
    locked,
} = .unlocked,
lock: ?*wlr.SessionLockV1 = null,

/// Limit on how long the locked event will be delayed to wait for
/// lock surfaces to be created and rendered. If this times out, then
/// the locked event will be sent immediately after all outputs have
/// been blanked.
lock_surfaces_timer: *wl.EventSource,

new_lock: wl.Listener(*wlr.SessionLockV1) = .init(handleLock),
unlock: wl.Listener(void) = .init(handleUnlock),
destroy: wl.Listener(void) = .init(handleDestroy),
new_surface: wl.Listener(*wlr.SessionLockSurfaceV1) = .init(handleSurface),

pub fn init(manager: *LockManager) !void {
    const event_loop = server.wl_server.getEventLoop();
    const timer = try event_loop.addTimer(*LockManager, handleLockSurfacesTimeout, manager);
    errdefer timer.remove();

    manager.* = .{
        .wlr_manager = try wlr.SessionLockManagerV1.create(server.wl_server),
        .lock_surfaces_timer = timer,
    };

    manager.wlr_manager.events.new_lock.add(&manager.new_lock);
}

pub fn deinit(manager: *LockManager) void {
    // deinit() should only be called after wl.Server.destroyClients()
    assert(manager.lock == null);

    manager.lock_surfaces_timer.remove();

    manager.new_lock.link.remove();
}

fn handleLock(listener: *wl.Listener(*wlr.SessionLockV1), lock: *wlr.SessionLockV1) void {
    const manager: *LockManager = @fieldParentPtr("new_lock", listener);

    log.debug("session lock client made lock request", .{});

    if (manager.lock != null) {
        log.info("denying new session lock client, an active one already exists", .{});
        lock.destroy();
        return;
    }

    manager.lock = lock;

    if (manager.state == .unlocked) {
        manager.state = .waiting_for_lock_surfaces;

        assert(!server.scene.locked_tree.node.enabled);
        server.scene.locked_tree.node.setEnabled(true);

        manager.lock_surfaces_timer.timerUpdate(200) catch {
            log.err("error setting lock surfaces timer, imperfect frames may be shown", .{});
            manager.state = .waiting_for_blank;
            // This call is necessary in the case that all outputs in the layout are disabled.
            manager.maybeLock();
        };

        {
            var it = server.input_manager.seats.iterator(.forward);
            while (it.next()) |seat| {
                seat.focus(.none);
            }
        }
    } else {
        if (manager.state == .locked) {
            lock.sendLocked();
        }

        log.info("new session lock client given control of already locked session", .{});
    }

    lock.events.new_surface.add(&manager.new_surface);
    lock.events.unlock.add(&manager.unlock);
    lock.events.destroy.add(&manager.destroy);
}

fn handleLockSurfacesTimeout(manager: *LockManager) c_int {
    log.err("waiting for lock surfaces timed out, imperfect frames may be shown", .{});

    assert(manager.state == .waiting_for_lock_surfaces);
    manager.state = .waiting_for_blank;

    server.scene.normal_tree.node.setEnabled(false);

    // This call is necessary in the case that all outputs in the layout are disabled.
    manager.maybeLock();

    return 0;
}

pub fn maybeLock(manager: *LockManager) void {
    var all_outputs_blanked = true;
    var all_outputs_rendered_lock_surface = true;
    {
        var it = server.om.outputs.iterator(.forward);
        while (it.next()) |output| {
            const wlr_output = output.wlr_output orelse continue;
            if (!wlr_output.enabled) continue;

            switch (output.lock_render_state) {
                .pending_unlock, .unlocked, .pending_blank, .pending_lock_surface => {
                    all_outputs_blanked = false;
                    all_outputs_rendered_lock_surface = false;
                },
                .blanked => {
                    all_outputs_rendered_lock_surface = false;
                },
                .lock_surface => {},
            }
        }
    }

    switch (manager.state) {
        .waiting_for_lock_surfaces => if (all_outputs_rendered_lock_surface) {
            manager.sendLocked();
            server.scene.normal_tree.node.setEnabled(false);
            manager.lock_surfaces_timer.timerUpdate(0) catch {};
        },
        .waiting_for_blank => if (all_outputs_blanked) {
            manager.sendLocked();
        },
        .unlocked, .locked => unreachable,
    }
}

fn sendLocked(manager: *LockManager) void {
    log.info("session locked", .{});
    // The lock client may have been destroyed, for example due to a protocol error.
    if (manager.lock) |lock| lock.sendLocked();
    manager.state = .locked;
    server.wm.dirtyWindowing();
}

fn handleUnlock(listener: *wl.Listener(void)) void {
    const manager: *LockManager = @fieldParentPtr("unlock", listener);

    manager.state = .unlocked;

    log.info("session unlocked", .{});

    assert(!server.scene.normal_tree.node.enabled);
    server.scene.normal_tree.node.setEnabled(true);

    assert(server.scene.locked_tree.node.enabled);
    server.scene.locked_tree.node.setEnabled(false);

    {
        var it = server.input_manager.seats.iterator(.forward);
        while (it.next()) |seat| {
            seat.focus(.none);
        }
    }

    handleDestroy(&manager.destroy);

    server.wm.dirtyWindowing();
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const manager: *LockManager = @fieldParentPtr("destroy", listener);

    log.debug("ext_session_lock_v1 destroyed", .{});

    manager.new_surface.link.remove();
    manager.unlock.link.remove();
    manager.destroy.link.remove();

    manager.lock = null;
    if (manager.state == .waiting_for_lock_surfaces) {
        manager.state = .waiting_for_blank;
        manager.lock_surfaces_timer.timerUpdate(0) catch {};
    }
}

fn handleSurface(
    listener: *wl.Listener(*wlr.SessionLockSurfaceV1),
    wlr_lock_surface: *wlr.SessionLockSurfaceV1,
) void {
    const manager: *LockManager = @fieldParentPtr("new_surface", listener);

    log.debug("new ext_session_lock_surface_v1 created", .{});

    assert(manager.state != .unlocked);
    assert(manager.lock != null);

    LockSurface.create(wlr_lock_surface, manager.lock.?) catch {
        log.err("out of memory", .{});
        wlr_lock_surface.resource.postNoMemory();
    };
}

pub fn lockSurfaceFromOutput(manager: *LockManager, output: *Output) ?*LockSurface {
    const lock = manager.lock orelse return null;

    var it = lock.surfaces.iterator(.forward);
    while (it.next()) |wlr_lock_surface| {
        const lock_surface: *LockSurface = @ptrCast(@alignCast(wlr_lock_surface.data));
        if (output == lock_surface.getOutput()) {
            return lock_surface;
        }
    }

    return null;
}
