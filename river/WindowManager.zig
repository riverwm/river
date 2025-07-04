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
const Scene = @import("Scene.zig");
const Seat = @import("Seat.zig");
const ShellSurface = @import("ShellSurface.zig");
const Window = @import("Window.zig");
const WmNode = @import("WmNode.zig");

const log = std.log.scoped(.wm);

global: *wl.Global,
server_destroy: wl.Listener(*wl.Server) = .init(handleServerDestroy),

/// The protocol object of the active window manager, if any.
object: ?*river.WindowManagerV1 = null,

state: union(enum) {
    idle,
    /// Waiting on the window manager client to send manage_finish.
    manage,
    /// The number of configures sent that have not yet been acked
    inflight_configures: u32,
    /// Waiting on the window manager client to send render_finish.
    render,
} = .idle,

windows: wl.list.Head(Window, .link),

/// State to be sent to the wm in the next manage sequence.
wm_scheduled: struct {
    /// State has been modified since the last manage sequence.
    dirty: bool = false,

    output_config: ?*wlr.OutputConfigurationV1 = null,
} = .{},

/// State sent to the wm in the latest update sequence.
wm_sent: struct {
    outputs: wl.list.Head(Output, .link_sent),
    output_config: ?*wlr.OutputConfigurationV1 = null,

    seats: wl.list.Head(Seat, .link_sent),
},

/// Rendering state to be sent to the wm in the next render sequence.
rendering_scheduled: struct {
    /// Rendering state has been modified since the last render sequence.
    dirty: bool = false,
} = .{},

/// The list is in rendering order, the last node in the list is rendered on top.
rendering_requested: struct {
    list: wl.list.Head(WmNode, .link),
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
        .wm_sent = .{
            .outputs = undefined,
            .seats = undefined,
        },
        .rendering_requested = .{
            .list = undefined,
        },
        .timeout = timeout,
    };
    wm.windows.init();
    wm.wm_sent.outputs.init();
    wm.wm_sent.seats.init();
    wm.rendering_requested.list.init();

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
    wm.dirtyWindowing();
}

fn handleRequestInert(
    object: *river.WindowManagerV1,
    request: river.WindowManagerV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) object.destroy();
}

fn handleDestroy(_: *river.WindowManagerV1, wm: *WindowManager) void {
    log.debug("active river_window_manager_v1 destroyed", .{});
    wm.object = null;
    switch (wm.state) {
        .idle => {},
        .inflight_configures => {},
        .manage => wm.manageFinish(),
        .render => wm.renderFinish(),
    }
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
        .manage_finish => {
            if (wm.state != .manage) {
                wm_v1.postError(.sequence_order,
                    \\manage_finish request does not match manage_start
                );
                return;
            }
            wm.manageFinish();
        },
        .manage_dirty => wm.dirtyWindowing(),
        .render_finish => {
            if (wm.state != .render) {
                wm_v1.postError(.sequence_order,
                    \\render_finish request does not match render_start
                );
                return;
            }
            wm.renderFinish();
        },
        .get_shell_surface => |args| {
            const surface = wlr.Surface.fromWlSurface(args.surface);
            ShellSurface.create(
                wm_v1.getClient(),
                wm_v1.getVersion(),
                args.id,
                surface,
            ) catch {
                wm_v1.getClient().postNoMemory();
                log.err("out of memory", .{});
                return;
            };
        },
    }
}

pub fn ensureWindowing(wm: *WindowManager) bool {
    switch (wm.state) {
        .manage => return true,
        .idle, .inflight_configures, .render => {
            if (wm.object) |wm_v1| {
                wm_v1.postError(.sequence_order, "invalid modification of window management state");
            }
            return false;
        },
    }
}

pub fn ensureRendering(wm: *WindowManager) bool {
    switch (wm.state) {
        .manage, .inflight_configures, .render => return true,
        .idle => {
            if (wm.object) |wm_v1| {
                wm_v1.postError(.sequence_order, "invalid modification of rendering state");
            }
            return false;
        },
    }
}

pub fn dirtyWindowing(wm: *WindowManager) void {
    wm.wm_scheduled.dirty = true;

    if (wm.dirty_idle == null) {
        const event_loop = server.wl_server.getEventLoop();
        wm.dirty_idle = event_loop.addIdle(*WindowManager, dirtyIdle, wm) catch {
            log.err("out of memory", .{});
            return;
        };
    }
}

pub fn dirtyRendering(wm: *WindowManager) void {
    wm.rendering_scheduled.dirty = true;

    if (wm.dirty_idle == null) {
        const event_loop = server.wl_server.getEventLoop();
        wm.dirty_idle = event_loop.addIdle(*WindowManager, dirtyIdle, wm) catch {
            log.err("out of memory", .{});
            return;
        };
    }
}

fn dirtyIdle(wm: *WindowManager) void {
    assert(wm.wm_scheduled.dirty or wm.rendering_scheduled.dirty);
    wm.dirty_idle = null;
    switch (wm.state) {
        .idle => {
            if (wm.rendering_scheduled.dirty) {
                wm.renderStart();
            } else {
                wm.manageStart();
            }
        },
        .manage, .inflight_configures, .render => {},
    }
}

fn manageStart(wm: *WindowManager) void {
    assert(wm.state == .idle);
    assert(wm.wm_scheduled.dirty);

    log.debug("manage sequence start", .{});

    server.om.autoLayout();
    {
        var it = server.om.outputs.safeIterator(.forward);
        while (it.next()) |output| output.manageStart();
    }

    assert(wm.wm_sent.output_config == null);
    wm.wm_sent.output_config = wm.wm_scheduled.output_config;
    wm.wm_scheduled.output_config = null;

    {
        var it = wm.windows.safeIterator(.forward);
        while (it.next()) |window| window.manageStart();
    }

    {
        var it = server.input_manager.seats.safeIterator(.forward);
        while (it.next()) |seat| seat.manageStart();
    }

    wm.wm_scheduled.dirty = false;
    wm.state = .manage;

    if (wm.object) |wm_v1| {
        // TODO kill the WM on a very long timeout?
        wm_v1.sendManageStart();
    } else {
        wm.manageFinish();
    }
}

pub fn manageFinish(wm: *WindowManager) void {
    assert(wm.state == .manage);

    log.debug("manage sequence finish", .{});

    {
        // Order is important here, Seat.manageFinish() must be called
        // before Window.manageFinish().
        var it = wm.wm_sent.seats.iterator(.forward);
        while (it.next()) |seat| seat.manageFinish();
    }

    wm.state = .{ .inflight_configures = 0 };
    {
        var it = wm.rendering_requested.list.iterator(.forward);
        while (it.next()) |node| {
            switch (node.get()) {
                .window => |window| {
                    if (window.manageFinish()) {
                        wm.state.inflight_configures += 1;
                    }
                },
                .shell_surface => {},
            }
        }
    }

    log.debug("sent {} tracked configure(s)", .{wm.state.inflight_configures});

    if (wm.state.inflight_configures > 0) {
        wm.startTimeoutTimer();
    } else {
        wm.renderStart();
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

    assert(wm.state.inflight_configures > 0);
    wm.state.inflight_configures = 0;

    wm.renderStart();

    return 0;
}

pub fn notifyConfigured(wm: *WindowManager) void {
    wm.state.inflight_configures -= 1;
    if (wm.state.inflight_configures == 0) {
        wm.cancelTimeoutTimer();
        wm.renderStart();
    }
}

fn renderStart(wm: *WindowManager) void {
    assert(wm.state == .idle or wm.state.inflight_configures == 0);

    log.debug("render sequence start", .{});

    {
        var it = wm.rendering_requested.list.iterator(.forward);
        while (it.next()) |node| {
            switch (node.get()) {
                .window => |window| window.renderStart(),
                .shell_surface => {},
            }
        }
    }

    wm.state = .render;
    wm.rendering_scheduled.dirty = false;

    if (wm.object) |wm_v1| {
        // TODO kill the WM on a very long timeout?
        wm_v1.sendRenderStart();
    } else {
        wm.renderFinish();
    }
}

/// Finish the update sequence and drop stashed buffers. This means that
/// the next frame drawn will be the post-transaction state.
fn renderFinish(wm: *WindowManager) void {
    assert(wm.state == .render);
    wm.state = .idle;

    log.debug("render sequence finish", .{});

    {
        var it = wm.windows.safeIterator(.forward);
        while (it.next()) |window| {
            // If a window is unmapped during a render sequence, we need to retain the saved
            // buffers until after the next manage sequence (in which the closed event will
            // be sent) for frame perfection.
            if (window.wm_scheduled.state != .closing) {
                window.surfaces.dropSaved();
            }
            if (window.impl == .destroying) {
                window.destroy();
            }
        }
    }

    {
        var it = wm.rendering_requested.list.iterator(.forward);
        while (it.next()) |node| {
            switch (node.get()) {
                .window => |window| {
                    window.renderFinish();

                    window.tree.node.reparent(server.scene.layers.wm);
                    window.tree.node.raiseToTop();
                },
                .shell_surface => |shell_surface| {
                    shell_surface.renderFinish();

                    shell_surface.tree.node.reparent(server.scene.layers.wm);
                    shell_surface.tree.node.raiseToTop();
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

    if (wm.rendering_scheduled.dirty) {
        wm.dirtyRendering();
    } else if (wm.wm_scheduled.dirty) {
        wm.dirtyWindowing();
    } else {
        server.input_manager.processEvents();
    }
}
