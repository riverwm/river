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
},

/// State sent to the wm in the latest update sequence.
sent: struct {
    outputs: wl.list.Head(Output, .link_sent),
    output_config: ?*wlr.OutputConfigurationV1 = null,
},

/// State sent by the wm but not yet committed with a commit request.
uncommitted: struct {
    render_list: wl.list.Head(WmNode, .link_uncommitted),
},

/// State sent by the wm and committed with a commit request.
committed: struct {
    dirty: bool = false,
    render_list: wl.list.Head(WmNode, .link_committed),
},

/// State committed by the wm that has been sent to windows as part of the
/// current transaction.
inflight: struct {
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
        },
        .sent = .{
            .outputs = undefined,
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
    wm.sent.outputs.init();
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
    object.setHandler(*WindowManager, handleRequest, null, wm);
    // XXX send existing windows?
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

            wm.committed.dirty = true;
            switch (wm.state) {
                .idle, .update_acked => wm.sendConfigures(),
                .update_sent, .inflight_configures => {},
            }
        },
        .get_seat => |_| {},
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

    // XXX send all dirty pending state

    wm.autoLayoutOutputs();
    {
        var it = wm.pending.outputs.safeIterator(.forward);
        while (it.next()) |output| {
            output.sendDirty() catch {
                log.err("out of memory", .{});
                continue; // Try again next update
            };
        }
    }

    assert(wm.sent.output_config == null);
    wm.sent.output_config = wm.pending.output_config;
    wm.pending.output_config = null;

    {
        var it = wm.pending.dirty_windows.safeIterator(.forward);
        while (it.next()) |window| {
            window.sendDirty() catch {
                log.err("out of memory", .{});
                continue; // Try again next update
            };
        }
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

fn handleTimeout(wm: *WindowManager) c_int {
    log.err("timeout occurred, some imperfect frames may be shown", .{});

    switch (wm.state) {
        .idle => unreachable,
        .update_sent, .update_acked => wm.state = .idle,
        .inflight_configures => {
            wm.state.inflight_configures = 0;
            wm.commitTransaction();
        },
    }

    return 0;
}

pub fn notifyConfigured(wm: *WindowManager) void {
    wm.state.inflight_configures -= 1;
    if (wm.state.inflight_configures == 0) {
        // Disarm the timer, as we didn't timeout
        wm.timeout.timerUpdate(0) catch log.err("error disarming timer", .{});
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
        var it = wm.inflight.render_list.iterator(.forward);
        while (it.next()) |node| {
            switch (node.get()) {
                .window => |window| {
                    window.commitTransaction();

                    window.tree.node.reparent(server.scene.layers.wm);
                    window.tree.node.setEnabled(true);
                    window.popup_tree.node.setEnabled(true);
                },
            }
        }
    }

    server.om.commitOutputState();

    {
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) node.data.cursor.updateState();
    }

    {
        // This must be done after updating cursor state in case the window was the target of move/resize.
        var it = wm.inflight.render_list.safeIterator(.forward);
        while (it.next()) |node| {
            switch (node.get()) {
                .window => |window| {
                    window.dropSavedSurfaceTree();
                    if (window.destroying) window.destroy(.assert);
                },
            }
        }
    }

    server.idle_inhibit_manager.checkActive();

    log.debug("finished committing transaction", .{});

    if (wm.committed.dirty) {
        wm.sendConfigures();
    } else if (wm.pending.dirty) {
        wm.sendUpdate();
    }
}
