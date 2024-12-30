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
const wlr = @import("wlroots");
const river = @import("wayland").server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const Window = @import("Window.zig");
const WmNode = @import("WmNode.zig");

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
    /// The number of configures sent that have not yet been acked
    inflight_configures: u32,
} = .idle,

/// Pending state to be sent to the wm in the next update sequence.
pending: struct {
    /// Pending state has been modified since the last update event sent to the wm.
    dirty: bool = false,

    dirty_windows: wl.list.Head(Window, .link_dirty),

    outputs: wl.list.Head(Output, .link_pending),
    output_config: ?*wlr.OutputConfigurationV1 = null,

    seats: wl.list.Head(Seat, .link_pending),
},

/// State sent to the wm in the latest update sequence.
sent: struct {
    outputs: wl.list.Head(Output, .link_sent),
    output_config: ?*wlr.OutputConfigurationV1 = null,

    seats: wl.list.Head(Seat, .link_sent),
},

/// State sent by the wm but not yet committed with a commit request.
uncommitted: struct {
    /// The list is in rendering order, the last node in the list is rendered on top.
    render_list: wl.list.Head(WmNode, .link_uncommitted),
},

/// State sent by the wm and committed with a commit request.
committed: struct {
    // The wm has committed state since state was last sent to windows.
    dirty: bool = false,
    /// The list is in rendering order, the last node in the list is rendered on top.
    render_list: wl.list.Head(WmNode, .link_committed),
},

/// State committed by the wm that has been sent to windows as part of the
/// current transaction.
inflight: struct {
    /// The list is in rendering order, the last node in the list is rendered on top.
    render_list: wl.list.Head(WmNode, .link_inflight),
},

dirty_idle: ?*wl.EventSource = null,

timeout: *wl.EventSource,

pub fn init(wm: *WindowManager) !void {
    const event_loop = server.wl_server.getEventLoop();
    const timeout = try event_loop.addTimer(*WindowManager, handleTimeout, wm);
    errdefer timeout.remove();

    wm.* = .{
        .global = try wl.Global.create(server.wl_server, river.WindowManagerV1, 1, *WindowManager, wm, bind),
        .windows = undefined,
        .pending = .{
            .dirty_windows = undefined,
            .outputs = undefined,
            .seats = undefined,
        },
        .sent = .{
            .outputs = undefined,
            .seats = undefined,
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
        .timeout = timeout,
    };
    wm.windows.init();
    wm.pending.dirty_windows.init();
    wm.pending.outputs.init();
    wm.pending.seats.init();
    wm.sent.outputs.init();
    wm.sent.seats.init();
    wm.uncommitted.render_list.init();
    wm.committed.render_list.init();
    wm.inflight.render_list.init();

    server.wl_server.addDestroyListener(&wm.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const wm: *WindowManager = @fieldParentPtr("server_destroy", listener);

    wm.global.destroy();
    wm.timeout.remove();
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
    object.setHandler(*WindowManager, handleRequest, handleDestroy, wm);
    wm.dirtyPending();
}

fn handleRequestInert(
    object: *river.WindowManagerV1,
    request: river.WindowManagerV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) object.destroy();
}

fn handleDestroy(_: *river.WindowManagerV1, wm: *WindowManager) void {
    wm.object = null;
}

fn handleRequest(
    wm_v1: *river.WindowManagerV1,
    request: river.WindowManagerV1.Request,
    wm: *WindowManager,
) void {
    assert(wm.object == wm_v1);
    switch (request) {
        .stop => {
            wm.object = null;
            wm_v1.sendFinished();
            wm_v1.setHandler(?*anyopaque, handleRequestInert, null, null);
        },
        .destroy => {
            // XXX send protocol error
            wm_v1.destroy();
        },
        .ack_update => |args| {
            switch (wm.state) {
                .update_sent => |serial| {
                    if (args.serial == serial) {
                        wm.state = .update_acked;
                    }
                },
                .idle, .update_acked, .inflight_configures => {},
            }
        },
        .commit => {
            {
                var it = wm.uncommitted.render_list.iterator(.forward);
                while (it.next()) |node| {
                    node.link_committed.remove();
                    wm.committed.render_list.append(node);
                    switch (node.get()) {
                        .window => |window| window.commitWmState(),
                    }
                }
            }

            {
                var it = wm.sent.seats.iterator(.forward);
                while (it.next()) |seat| seat.commitWmState();
            }

            wm.committed.dirty = true;
            switch (wm.state) {
                .idle, .update_acked => {
                    wm.cancelTimeoutTimer();
                    wm.sendConfigures();
                },
                .update_sent, .inflight_configures => {},
            }
        },
        .get_shell_surface => |_| {},
    }
}

pub fn dirtyPending(wm: *WindowManager) void {
    wm.pending.dirty = true;

    if (wm.dirty_idle == null) {
        const event_loop = server.wl_server.getEventLoop();
        wm.dirty_idle = event_loop.addIdle(*WindowManager, handleDirtyPending, wm) catch {
            log.err("out of memory", .{});
            return;
        };
    }
}

fn handleDirtyPending(wm: *WindowManager) void {
    assert(wm.pending.dirty);
    wm.dirty_idle = null;
    switch (wm.state) {
        .idle => {
            assert(!wm.committed.dirty);
            wm.sendUpdate();
        },
        .update_sent, .update_acked, .inflight_configures => {},
    }
}

fn sendUpdate(wm: *WindowManager) void {
    assert(wm.state == .idle);
    assert(wm.pending.dirty);

    log.debug("sending update to window manager", .{});

    wm.autoLayoutOutputs();
    {
        var it = wm.pending.outputs.safeIterator(.forward);
        while (it.next()) |output| output.sendDirty();
    }

    assert(wm.sent.output_config == null);
    wm.sent.output_config = wm.pending.output_config;
    wm.pending.output_config = null;

    {
        var it = wm.pending.dirty_windows.safeIterator(.forward);
        while (it.next()) |window| window.sendDirty();
    }

    {
        var it = wm.pending.seats.safeIterator(.forward);
        while (it.next()) |seat| seat.sendDirty();
    }

    wm.pending.dirty = false;

    if (wm.object) |wm_v1| {
        const serial = server.wl_server.nextSerial();
        wm_v1.sendUpdate(serial);
        wm.state = .{ .update_sent = serial };

        wm.startTimeoutTimer();
    } else {
        // Pretend that the non-existent wm client made an empty commit.
        wm.committed.dirty = true;
        wm.sendConfigures();
    }
}

fn autoLayoutOutputs(wm: *WindowManager) void {
    // Find the right most edge of any non-autolayout output.
    var rightmost_edge: i32 = 0;
    var row_y: i32 = 0;
    {
        var it = wm.pending.outputs.iterator(.forward);
        while (it.next()) |output| {
            if (output.pending.auto_layout) continue;

            const x = output.pending.x + output.pending.width();
            if (x > rightmost_edge) {
                rightmost_edge = x;
                row_y = output.pending.y;
            }
        }
    }
    // Place autolayout outputs in a row starting at the rightmost edge.
    {
        var it = wm.pending.outputs.iterator(.forward);
        while (it.next()) |output| {
            if (!output.pending.auto_layout) continue;

            output.pending.x = rightmost_edge;
            output.pending.y = row_y;
            rightmost_edge += output.pending.width();
        }
    }
}

fn sendConfigures(wm: *WindowManager) void {
    switch (wm.state) {
        .idle, .update_acked => {},
        .update_sent, .inflight_configures => unreachable,
    }

    assert(wm.committed.dirty);
    wm.committed.dirty = false;

    {
        var it = wm.sent.seats.iterator(.forward);
        while (it.next()) |seat| seat.applyCommitted();
    }

    wm.state = .{ .inflight_configures = 0 };
    {
        var it = wm.committed.render_list.iterator(.forward);
        while (it.next()) |node| {
            node.link_inflight.remove();
            wm.inflight.render_list.append(node);
            switch (node.get()) {
                .window => |window| {
                    if (window.configure()) {
                        wm.state.inflight_configures += 1;
                    }
                },
            }
        }
    }

    log.debug("started transaction with {} configure(s)", .{wm.state.inflight_configures});

    if (wm.state.inflight_configures > 0) {
        wm.startTimeoutTimer();
    } else {
        wm.commitTransaction();
    }
}

fn startTimeoutTimer(wm: *WindowManager) void {
    wm.timeout.timerUpdate(100) catch {
        log.err("failed to start timer", .{});
        _ = wm.handleTimeout();
    };
}

fn cancelTimeoutTimer(wm: *WindowManager) void {
    wm.timeout.timerUpdate(0) catch log.err("error disarming timer", .{});
}

fn handleTimeout(wm: *WindowManager) c_int {
    log.err("timeout occurred, some imperfect frames may be shown", .{});

    assert(wm.state != .idle);

    wm.state = .{ .inflight_configures = 0 };
    wm.commitTransaction();

    return 0;
}

pub fn notifyConfigured(wm: *WindowManager) void {
    wm.state.inflight_configures -= 1;
    if (wm.state.inflight_configures == 0) {
        wm.cancelTimeoutTimer();
        wm.commitTransaction();
    }
}

/// Apply the inflight state and drop stashed buffers. This means that
/// the next frame drawn will be the post-transaction state of the
/// layout. Should only be called after all clients have configured for
/// the new layout. If called early imperfect frames may be drawn.
fn commitTransaction(wm: *WindowManager) void {
    assert(wm.state.inflight_configures == 0);
    wm.state = .idle;

    log.debug("commiting transaction", .{});

    {
        var it = wm.windows.safeIterator(.forward);
        while (it.next()) |window| {
            window.dropSavedSurfaceTree();
            if (window.destroying) window.destroy(.assert);
        }
    }

    {
        var it = wm.inflight.render_list.iterator(.forward);
        while (it.next()) |node| {
            switch (node.get()) {
                .window => |window| {
                    window.commitTransaction();

                    window.tree.node.reparent(server.scene.layers.wm);
                    window.tree.node.raiseToTop();
                    window.tree.node.setEnabled(!window.current.hidden);
                    window.popup_tree.node.setEnabled(!window.current.hidden);
                },
            }
        }
    }

    server.om.commitOutputState();

    {
        var it = server.input_manager.seats.iterator(.forward);
        while (it.next()) |seat| seat.cursor.updateState();
    }

    server.idle_inhibit_manager.checkActive();

    log.debug("finished committing transaction", .{});

    if (wm.committed.dirty) {
        wm.sendConfigures();
    } else if (wm.pending.dirty) {
        wm.dirtyPending();
    } else {
        server.input_manager.processEvents();
    }
}
