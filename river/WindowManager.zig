// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2024 The River Developers
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

const WindowManager = @This();

const std = @import("std");
const assert = std.debug.assert;
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Window = @import("Window.zig");

const log = std.log.scoped(.wm);

global: *wl.Global,
server_destroy: wl.Listener(*wl.Server) = wl.Listener(*wl.Server).init(handleServerDestroy),

/// The protocol object of the active window manager, if any.
object: ?*river.WindowManagerV1 = null,

windows: wl.list.Head(Window, .link),

state: union(enum) {
    idle,
    /// An update event was sent to the window manager but has not yet been acked.
    /// Value is the update serial
    update_sent: u32,
    /// An update event was sent to the window manager and has been acked but not yet committed.
    update_acked,
    /// The number of configures sent that have not yet been ack'd
    configures_inflight: u32,
} = .idle,

/// Pending state from windows to be sent to the wm in the next update sequence.
pending: struct {
    /// Pending state has been modified since the last update event sent to the wm.
    dirty: bool = false,
    new_windows: wl.list.Head(Window, .link_new),
},

/// State sent by the wm but not yet committed with a commit request.
uncommitted: struct {
    render_list: wl.list.Head(Window, .uncommitted_render_list_link),
},

/// State sent by the wm and committed with a commit request.
committed: struct {
    dirty: bool = false,
    render_list: wl.list.Head(Window, .committed_render_list_link),
},

/// State committed by the wm that has been sent to windows as part of the
/// current transaction.
inflight: struct {
    render_list: wl.list.Head(Window, .inflight_render_list_link),
},

dirty_idle: ?*wl.EventSource = null,

/// Number of inflight configures sent to windows in the current transaction.
inflight_configures: u32 = 0,
transaction_timeout: *wl.EventSource,

pub fn init(wm: *WindowManager) !void {
    const event_loop = server.wl_server.getEventLoop();
    const transaction_timeout = try event_loop.addTimer(*WindowManager, handleTransactionTimeout, wm);
    errdefer transaction_timeout.remove();

    wm.* = .{
        .global = try wl.Global.create(server.wl_server, river.WindowManagerV1, 1, *WindowManager, wm, bind),
        .windows = undefined,
        .pending = .{
            .new_windows = undefined,
        },
        .uncommitted = .{
            .render_list = undefined,
        },
        .committed = .{
            .render_list = undefined,
        },
        .inflight = .{
            .render_list = undefined,
        },
        .transaction_timeout = transaction_timeout,
    };
    wm.windows.init();
    wm.pending.new_windows.init();
    wm.uncommitted.render_list.init();
    wm.committed.render_list.init();
    wm.inflight.render_list.init();

    server.wl_server.addDestroyListener(&wm.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const wm: *WindowManager = @fieldParentPtr("server_destroy", listener);

    wm.global.destroy();
    wm.transaction_timeout.remove();
}

fn bind(client: *wl.Client, wm: *WindowManager, version: u32, id: u32) void {
    const object = river.WindowManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };

    if (wm.object != null) {
        object.sendUnavailable();
        object.setHandler(?*anyopaque, handleRequestInert, null, null);
        return;
    }

    wm.object = object;
    object.setHandler(*WindowManager, handleRequest, null, wm);
}

fn handleRequestInert(
    object: *river.WindowManagerV1,
    request: river.WindowManagerV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) object.destroy();
}

fn handleRequest(
    object: *river.WindowManagerV1,
    request: river.WindowManagerV1.Request,
    wm: *WindowManager,
) void {
    assert(wm.object == object);
    switch (request) {
        .stop => {
            wm.object = null;
            object.sendFinished();
            object.setHandler(?*anyopaque, handleRequestInert, null, null);
        },
        .destroy => {
            // XXX send protocol error
        },
        .ack_update => |_| {},
        .commit => {},
        .get_seat => |_| {},
        .get_shell_surface => |_| {},
    }
}

pub fn dirtyPending(wm: *WindowManager) void {
    wm.pending.dirty = true;

    if (wm.dirty_idle == null) {
        const event_loop = server.wl_server.getEventLoop();
        wm.dirty_idle = event_loop.addIdle(*WindowManager, handleDirty, wm) catch {
            log.err("out of memory", .{});
            return;
        };
    }
}

fn handleDirty(wm: *WindowManager) void {
    switch (wm.state) {
        .idle => {
            assert(!wm.committed.dirty);

            if (wm.pending.dirty) {
                wm.sendUpdate();
            }
        },
        .update_sent, .update_acked, .configures_inflight => {},
    }
}

fn sendUpdate(wm: *WindowManager) void {
    assert(wm.state == .idle);

    const wm_v1 = wm.object orelse return;

    // XXX send all dirty pending state

    wm.pending.dirty = false;

    const serial = server.wl_server.nextSerial();
    wm_v1.sendUpdate(serial);
    wm.state = .{ .update_sent = serial };
}

fn sendConfigures(wm: *WindowManager) void {
    assert(wm.inflight_configures == 0);

    {
        var it = wm.inflight.render_list.iterator(.forward);
        while (it.next()) |window| {
            assert(!window.inflight_transaction);
            window.inflight_transaction = true;

            // This can happen if a window is unmapped while a layout demand including it is inflight
            // If a window has been unmapped, don't send it a configure.
            if (!window.mapped) continue;

            if (window.configure()) {
                wm.inflight_configures += 1;

                window.saveSurfaceTree();
                window.sendFrameDone();
            }
        }
    }

    if (wm.inflight_configures > 0) {
        std.log.scoped(.transaction).debug("started transaction with {} pending configure(s)", .{
            wm.inflight_configures,
        });

        wm.transaction_timeout.timerUpdate(100) catch {
            std.log.scoped(.transaction).err("failed to update timer", .{});
            wm.commitTransaction();
        };
    } else {
        wm.commitTransaction();
    }
}

fn handleTransactionTimeout(wm: *WindowManager) c_int {
    std.log.scoped(.transaction).err("timeout occurred, some imperfect frames may be shown", .{});

    wm.inflight_configures = 0;
    wm.commitTransaction();

    return 0;
}

pub fn notifyConfigured(wm: *WindowManager) void {
    wm.inflight_configures -= 1;
    if (wm.inflight_configures == 0) {
        // Disarm the timer, as we didn't timeout
        wm.transaction_timeout.timerUpdate(0) catch std.log.scoped(.transaction).err("error disarming timer", .{});
        wm.commitTransaction();
    }
}

/// Apply the inflight state and drop stashed buffers. This means that
/// the next frame drawn will be the post-transaction state of the
/// layout. Should only be called after all clients have configured for
/// the new layout. If called early imperfect frames may be drawn.
fn commitTransaction(wm: *WindowManager) void {
    assert(wm.inflight_configures == 0);

    std.log.scoped(.transaction).debug("commiting transaction", .{});

    {
        var it = wm.inflight.render_list.iterator(.forward);
        while (it.next()) |window| {
            window.commitTransaction();

            window.tree.node.setEnabled(true);
            window.popup_tree.node.setEnabled(true);
        }
    }

    {
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) node.data.cursor.updateState();
    }

    {
        // This must be done after updating cursor state in case the window was the target of move/resize.
        var it = wm.inflight.render_list.safeIterator(.forward);
        while (it.next()) |window| {
            window.dropSavedSurfaceTree();
            if (window.destroying) window.destroy(.assert);
        }
    }

    server.idle_inhibit_manager.checkActive();

    if (wm.pending.dirty) {
        wm.dirtyPending();
    }
}