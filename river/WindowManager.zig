// SPDX-FileCopyrightText: © 2024 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const WindowManager = @This();

const std = @import("std");
const assert = std.debug.assert;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const river = @import("wayland").server.river;
const SlotMap = @import("slotmap").SlotMap;

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

windows: SlotMap(*Window) = .empty,

/// State to be sent to the wm in the next manage sequence.
scheduled: struct {
    /// State has been modified since the last manage sequence.
    dirty: bool = false,

    output_config: ?*wlr.OutputConfigurationV1 = null,
} = .{},

/// State sent to the wm in the latest update sequence.
sent: struct {
    session_locked: bool = false,

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
    order_hash: u64 = 0,
},

dirty_idle: ?*wl.EventSource = null,

timeout: *wl.EventSource,

pub fn init(wm: *WindowManager) !void {
    const event_loop = server.wl_server.getEventLoop();
    const timeout = try event_loop.addTimer(*WindowManager, handleTimeout, wm);
    errdefer timeout.remove();

    wm.* = .{
        .global = try wl.Global.create(server.wl_server, river.WindowManagerV1, 3, *WindowManager, wm, bind),
        .sent = .{
            .outputs = undefined,
            .seats = undefined,
        },
        .rendering_requested = .{
            .list = undefined,
        },
        .timeout = timeout,
    };
    wm.sent.outputs.init();
    wm.sent.seats.init();
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
        // TODO send protocol error to avoid leak on race
        .destroy => wm_v1.destroy(),
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
    wm.scheduled.dirty = true;
    wm.addDirtyIdle();
}

pub fn cleanWindowing(wm: *WindowManager) void {
    wm.scheduled.dirty = false;
    wm.removeDirtyIdle();
}

pub fn dirtyRendering(wm: *WindowManager) void {
    wm.rendering_scheduled.dirty = true;
    wm.addDirtyIdle();
}

pub fn cleanRendering(wm: *WindowManager) void {
    wm.rendering_scheduled.dirty = false;
    wm.removeDirtyIdle();
}

fn addDirtyIdle(wm: *WindowManager) void {
    assert(wm.scheduled.dirty or wm.rendering_scheduled.dirty);
    if (wm.dirty_idle == null) {
        const event_loop = server.wl_server.getEventLoop();
        wm.dirty_idle = event_loop.addIdle(*WindowManager, dirtyIdle, wm) catch {
            log.err("out of memory", .{});
            return;
        };
    }
}

fn removeDirtyIdle(wm: *WindowManager) void {
    if (!wm.scheduled.dirty and !wm.rendering_scheduled.dirty) {
        if (wm.dirty_idle) |event_source| {
            event_source.remove();
            wm.dirty_idle = null;
        }
    }
}

fn dirtyIdle(wm: *WindowManager) void {
    assert(wm.scheduled.dirty or wm.rendering_scheduled.dirty);
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
    assert(wm.scheduled.dirty);
    wm.cleanWindowing();
    wm.state = .manage;

    log.debug("manage sequence start", .{});

    const session_locked = server.lock_manager.state == .locked;
    if (session_locked != wm.sent.session_locked) {
        if (wm.object) |wm_v1| {
            if (session_locked) {
                wm_v1.sendSessionLocked();
            } else {
                wm_v1.sendSessionUnlocked();
            }
        }
        wm.sent.session_locked = session_locked;
    }

    server.om.autoLayout();
    {
        var it = server.om.outputs.safeIterator(.forward);
        while (it.next()) |output| output.manageStart();
    }

    assert(wm.sent.output_config == null);
    wm.sent.output_config = wm.scheduled.output_config;
    wm.scheduled.output_config = null;

    {
        var it = wm.windows.iterator();
        while (it.next()) |window| window.manageStart();
    }

    {
        var it = server.input_manager.seats.safeIterator(.forward);
        while (it.next()) |seat| seat.manageStart();
    }

    if (wm.object) |wm_v1| {
        wm_v1.sendManageStart();
        wm.startTimeoutTimer(3000);
    } else {
        wm.manageFinish();
    }
}

pub fn manageFinish(wm: *WindowManager) void {
    assert(wm.state == .manage);
    wm.cancelTimeoutTimer();

    log.debug("manage sequence finish", .{});

    {
        // Order is important here, Seat.manageFinish() must be called
        // before Window.manageFinish().
        var it = wm.sent.seats.iterator(.forward);
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
        wm.startTimeoutTimer(100);
    } else {
        wm.renderStart();
    }
}

fn startTimeoutTimer(wm: *WindowManager, ms: u31) void {
    wm.timeout.timerUpdate(ms) catch {
        log.err("failed to start timer", .{});
        _ = wm.handleTimeout();
    };
}

fn cancelTimeoutTimer(wm: *WindowManager) void {
    wm.timeout.timerUpdate(0) catch log.err("error disarming timer", .{});
}

fn handleTimeout(wm: *WindowManager) c_int {
    switch (wm.state) {
        .inflight_configures => {
            log.err("timeout occurred, some imperfect frames may be shown", .{});
            assert(wm.state.inflight_configures > 0);
            wm.state.inflight_configures = 0;

            wm.renderStart();
        },
        .manage, .render => {
            log.err("window manager unresponsive for more than 3 seconds, disconnecting", .{});
            wm.object.?.postError(.unresponsive, "unresponsive for more than 3 seconds");
            // Don't wait for the frozen client to receive the protocol error
            // and exit of its own accord.
            wm.object.?.getClient().destroy();
        },
        .idle => unreachable,
    }

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
    assert((wm.state == .idle and wm.rendering_scheduled.dirty) or
        wm.state.inflight_configures == 0);
    wm.state = .render;
    wm.cleanRendering();

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

    if (wm.object) |wm_v1| {
        wm_v1.sendRenderStart();
        wm.startTimeoutTimer(3000);
    } else {
        wm.renderFinish();
    }
}

/// Finish the update sequence and drop stashed buffers. This means that
/// the next frame drawn will be the post-transaction state.
fn renderFinish(wm: *WindowManager) void {
    assert(wm.state == .render);
    wm.state = .idle;

    wm.cancelTimeoutTimer();

    log.debug("render sequence finish", .{});

    {
        var it = wm.windows.iterator();
        while (it.next()) |window| {
            // If a window is unmapped during a render sequence, we need to retain the saved
            // buffers until after the next manage sequence (in which the closed event will
            // be sent) for frame perfection.
            if (window.state != .closing) {
                window.surfaces.dropSaved();
            }
            // Ensure windows that are closed but not yet destroyed don't have
            // their borders/decorations rendered.
            if (window.state == .init) {
                window.tree.node.reparent(server.scene.hidden_tree);
            }
            if (window.impl == .destroying) {
                window.destroy();
            }
        }
    }

    // This is a hack to avoid excessive modification of the wlroots scene graph.
    // There is currently no way to atomically apply multiple changes to the
    // scene graph, which means that damage and visibility are re-calculated
    // every API call, resulting in redundant events being sent to clients.
    //
    // TODO(wlroots) provide a way to batch changes to the scene graph.
    const new_order_hash = blk: {
        var hash = std.crypto.hash.Blake3.init(.{});
        var it = wm.rendering_requested.list.iterator(.forward);
        while (it.next()) |node| {
            switch (node.get()) {
                .window => |window| {
                    hash.update(@ptrCast(&window.ref));
                    hash.update(&.{@intFromBool(window.wm_requested.fullscreen != null)});
                },
                .shell_surface => |shell_surface| {
                    hash.update(@ptrCast(&shell_surface));
                },
            }
        }
        var final: u64 = undefined;
        hash.final(@ptrCast(&final));
        break :blk final;
    };

    {
        const reorder = wm.rendering_requested.order_hash != new_order_hash;
        wm.rendering_requested.order_hash = new_order_hash;

        var found_fullscreen: bool = false;
        var it = wm.rendering_requested.list.iterator(.forward);
        while (it.next()) |node| {
            switch (node.get()) {
                .window => |window| {
                    window.renderFinish();
                    if (!reorder) continue;
                    window.popup_tree.node.reparent(server.scene.layers.popups);
                    if (window.wm_requested.fullscreen != null) {
                        window.tree.node.reparent(server.scene.layers.fullscreen);
                        window.tree.node.raiseToTop();
                        found_fullscreen = true;
                    } else {
                        window.tree.node.reparent(server.scene.layers.wm);
                        window.tree.node.raiseToTop();
                    }
                },
                .shell_surface => |shell_surface| {
                    shell_surface.renderFinish();
                    if (!reorder) continue;
                    shell_surface.popup_tree.node.reparent(server.scene.layers.popups);
                    if (found_fullscreen) {
                        shell_surface.tree.node.reparent(server.scene.layers.fullscreen);
                    } else {
                        shell_surface.tree.node.reparent(server.scene.layers.wm);
                    }
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
    } else if (wm.scheduled.dirty) {
        wm.dirtyWindowing();
    } else {
        server.input_manager.processEvents();
    }
}
