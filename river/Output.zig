// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020-2025 The River Developers
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

const Output = @This();

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const posix = std.posix;
const fmt = std.fmt;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;
const river = wayland.server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const LayerShellOutput = @import("LayerShellOutput.zig");
const LockSurface = @import("LockSurface.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Window = @import("Window.zig");
const Config = @import("Config.zig");

const log = std.log.scoped(.output);

pub const State = struct {
    state: enum {
        /// Powered on and exposed to the window manager
        enabled,
        /// Powered off and exposed to the window manager
        disabled_soft,
        /// Powered off and hidden from the window manager
        disabled_hard,
        /// Corresponding hardware no longer present
        destroying,
    } = .disabled_hard,
    /// Logical coordinate space
    x: i32 = 0,
    /// Logical coordinate space
    y: i32 = 0,
    /// The width/height of modes is in physical pixels, not in the
    /// compositors logical coordinate space.
    mode: union(enum) {
        standard: *wlr.Output.Mode,
        custom: struct {
            width: i32 = 0,
            height: i32 = 0,
            refresh: i32 = 0,
        },
        /// Used before the initial modeset and after the wlr_output is destroyed.
        none,
    } = .none,
    scale: f32 = 1,
    transform: wl.Output.Transform = .normal,
    adaptive_sync: bool,
    auto_layout: bool = true,

    /// Width/height in the logical coordinate space
    pub fn dimensions(state: *const State) struct { u31, u31 } {
        var w: i32, var h: i32 = switch (state.mode) {
            .standard => |mode| .{ mode.width, mode.height },
            .custom => |mode| .{ mode.width, mode.height },
            .none => .{ 0, 0 },
        };
        if (@mod(@intFromEnum(state.transform), 2) != 0) {
            mem.swap(i32, &w, &h);
        }
        return .{
            @intFromFloat(@as(f32, @floatFromInt(w)) / state.scale),
            @intFromFloat(@as(f32, @floatFromInt(h)) / state.scale),
        };
    }

    pub fn box(state: *const State) wlr.Box {
        const w, const h = state.dimensions();
        return .{ .x = state.x, .y = state.y, .width = w, .height = h };
    }

    pub fn applyNoModeset(state: *const State, wlr_state: *wlr.Output.State) void {
        wlr_state.setScale(state.scale);
        wlr_state.setTransform(state.transform);
    }

    pub fn applyModeset(state: *const State, wlr_state: *wlr.Output.State) void {
        const enabled = state.state == .enabled;
        wlr_state.setEnabled(enabled);
        if (!enabled) return;
        state.applyNoModeset(wlr_state);
        switch (state.mode) {
            .standard => |mode| wlr_state.setMode(mode),
            .custom => |mode| wlr_state.setCustomMode(mode.width, mode.height, mode.refresh),
            .none => {},
        }
        wlr_state.setAdaptiveSyncEnabled(state.adaptive_sync);
    }
};

/// Set to null when the wlr_output is destroyed.
wlr_output: ?*wlr.Output,
scene_output: ?*wlr.SceneOutput,

object: ?*river.OutputV1 = null,
layer_shell: LayerShellOutput = .{},

/// Tracks the currently presented frame on the output as it pertains to ext-session-lock.
/// The output is initially considered blanked:
/// If using the DRM backend it will be blanked with the initial modeset.
/// If using the Wayland or X11 backend nothing will be visible until the first frame is rendered.
lock_render_state: enum {
    /// Submitted an unlocked buffer but the buffer has not yet been presented.
    pending_unlock,
    /// Normal, "unlocked" content may be visible.
    unlocked,
    /// Submitted a blank buffer but the buffer has not yet been presented.
    /// Normal, "unlocked" content may be visible.
    pending_blank,
    /// A blank buffer has been presented.
    blanked,
    /// Submitted the lock surface buffer but the buffer has not yet been presented.
    /// Normal, "unlocked" content may be visible.
    pending_lock_surface,
    /// The lock surface buffer has been presented.
    lock_surface,
} = .blanked,

/// Root.outputs
link: wl.list.Link,

/// State to be sent to the wm in the next manage sequence.
scheduled: State,
/// State sent to the wm in the latest manage sequence.
sent: State,
link_sent: wl.list.Link,
sent_wl_output: bool = false,
/// State applied to the wlr_output and rendered.
current: State,

destroy: wl.Listener(*wlr.Output) = .init(handleDestroy),
request_state: wl.Listener(*wlr.Output.event.RequestState) = .init(handleRequestState),
frame: wl.Listener(*wlr.Output) = .init(handleFrame),
present: wl.Listener(*wlr.Output.event.Present) = .init(handlePresent),

pub fn create(wlr_output: *wlr.Output) !void {
    const output = try util.gpa.create(Output);
    errdefer util.gpa.destroy(output);

    {
        const title = try fmt.allocPrintSentinel(util.gpa, "river - {s}", .{wlr_output.name}, 0);
        defer util.gpa.free(title);
        if (wlr_output.isWl()) {
            wlr_output.wlSetTitle(title);
        } else if (wlr.config.has_x11_backend and wlr_output.isX11()) {
            wlr_output.x11SetTitle(title);
        }
    }

    if (!wlr_output.initRender(server.allocator, server.renderer)) return error.InitRenderFailed;

    const scene_output = try server.scene.wlr_scene.createSceneOutput(wlr_output);

    errdefer comptime unreachable;

    output.* = .{
        .wlr_output = wlr_output,
        .scene_output = scene_output,
        .scheduled = .{ .adaptive_sync = wlr_output.adaptive_sync_status == .enabled },
        .sent = .{ .adaptive_sync = wlr_output.adaptive_sync_status == .enabled },
        .current = .{ .adaptive_sync = wlr_output.adaptive_sync_status == .enabled },
        .link = undefined,
        .link_sent = undefined,
    };
    wlr_output.data = output;

    server.om.outputs.append(output);
    output.link_sent.init();

    wlr_output.events.destroy.add(&output.destroy);
    wlr_output.events.request_state.add(&output.request_state);
    wlr_output.events.frame.add(&output.frame);
    wlr_output.events.present.add(&output.present);

    output.scheduled.state = .enabled;
    if (wlr_output.preferredMode()) |preferred_mode| {
        output.scheduled.mode = .{ .standard = preferred_mode };
    } else {
        // Use a reasonable default so we can assert(mode != .none) for enabled
        // outputs in manageStart().
        output.scheduled.mode = .{ .custom = .{ .width = 1280, .height = 720, .refresh = 0 } };
    }

    server.wm.dirtyWindowing();
}

fn handleDestroy(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("destroy", listener);

    log.debug("wlr_output '{s}' destroyed", .{wlr_output.name});

    {
        var it = server.layer_shell.surfaces.iterator();
        while (it.next()) |surface| {
            if (surface.wlr_layer_surface.output == wlr_output) {
                surface.wlr_layer_surface.destroy();
            }
        }
    }

    output.destroy.link.remove();
    output.request_state.link.remove();
    output.frame.link.remove();
    output.present.link.remove();

    wlr_output.data = null;

    output.wlr_output = null;
    output.scene_output = null;
    output.scheduled.mode = .none;
    output.sent.mode = .none;
    output.current.mode = .none;
    output.scheduled.state = .destroying;

    server.wm.dirtyWindowing();
}

pub fn manageStart(output: *Output) void {
    switch (output.scheduled.state) {
        .enabled, .disabled_soft => {
            // We cannot send 0 width/height to the window manager client.
            assert(output.scheduled.mode != .none);

            const wlr_output = output.wlr_output.?;

            output.layer_shell.manageStart();

            if (server.wm.object) |wm_v1| {
                const new = output.object == null;
                const output_v1 = output.object orelse blk: {
                    const output_v1 = river.OutputV1.create(wm_v1.getClient(), wm_v1.getVersion(), 0) catch {
                        log.err("out of memory", .{});
                        return; // try again next update
                    };
                    output.object = output_v1;

                    output_v1.setHandler(*Output, handleRequest, handleObjectDestroy, output);
                    wm_v1.sendOutput(output_v1);

                    break :blk output_v1;
                };
                errdefer comptime unreachable;

                if (!output.sent_wl_output) {
                    // wl_output globals are created/destroyed by the wlroots output layout.
                    if (wlr_output.global) |global| {
                        output_v1.sendWlOutput(global.getName(output_v1.getClient()));
                        output.sent_wl_output = true;
                    }
                }

                const scheduled = &output.scheduled;
                const sent = &output.sent;

                const scheduled_width, const scheduled_height = scheduled.dimensions();
                const sent_width, const sent_height = sent.dimensions();

                if (new or scheduled_width != sent_width or scheduled_height != sent_height) {
                    output_v1.sendDimensions(scheduled_width, scheduled_height);
                }
                if (new or scheduled.x != sent.x or scheduled.y != sent.y) {
                    output_v1.sendPosition(scheduled.x, scheduled.y);
                }
            }

            output.sent = output.scheduled;

            output.link_sent.remove();
            server.wm.sent.outputs.append(output);
        },
        .disabled_hard, .destroying => {
            if (output.object) |output_v1| {
                output_v1.sendRemoved();
                output_v1.setHandler(?*anyopaque, handleRequestInert, null, null);
                output.layer_shell.makeInert();
                output.object = null;
            }

            output.sent = output.scheduled;

            if (output.scheduled.state == .destroying) {
                assert(output.wlr_output == null);
                {
                    var it = server.wm.windows.iterator();
                    while (it.next()) |window| {
                        switch (window.wm_scheduled.fullscreen_requested) {
                            .fullscreen => |output_hint| {
                                if (output_hint == output) {
                                    window.wm_scheduled.fullscreen_requested = .{ .fullscreen = null };
                                }
                            },
                            .no_request, .exit => {},
                        }
                        if (window.wm_requested.fullscreen == output) {
                            window.wm_requested.fullscreen = null;
                        }
                    }
                }
                output.link.remove();
                output.link_sent.remove();

                util.gpa.destroy(output);
            }
        },
    }
}

fn handleRequestInert(
    output_v1: *river.OutputV1,
    request: river.OutputV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) output_v1.destroy();
}

fn handleObjectDestroy(_: *river.OutputV1, output: *Output) void {
    output.object = null;
}

fn handleRequest(
    output_v1: *river.OutputV1,
    request: river.OutputV1.Request,
    output: *Output,
) void {
    assert(output.object == output_v1);
    switch (request) {
        .destroy => output_v1.destroy(),
    }
}

fn handleRequestState(listener: *wl.Listener(*wlr.Output.event.RequestState), event: *wlr.Output.event.RequestState) void {
    const output: *Output = @fieldParentPtr("request_state", listener);

    // The only state currently requested by a wlroots backend is a
    // custom mode as the Wayland/X11 backend window is resized.
    const committed: u32 = @bitCast(event.state.committed);
    const supported: u32 = @bitCast(wlr.Output.State.Fields{ .mode = true });

    if (committed != supported) {
        log.err("backend requested unsupported state {}", .{committed});
        return;
    }

    log.debug("backend requested new mode", .{});

    if (event.state.mode) |mode| {
        output.scheduled.mode = .{ .standard = mode };
    } else {
        output.scheduled.mode = .{ .custom = .{
            .width = event.state.custom_mode.width,
            .height = event.state.custom_mode.height,
            .refresh = event.state.custom_mode.refresh,
        } };
    }

    server.wm.dirtyWindowing();
}

fn handleFrame(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("frame", listener);

    // TODO this should probably be retried on failure
    output.renderAndCommit() catch |err| switch (err) {
        error.CommitFailed => log.err("output commit failed for {s}", .{wlr_output.name}),
    };

    var now = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch @panic("CLOCK_MONOTONIC not supported");
    output.scene_output.?.sendFrameDone(&now);
}

fn renderAndCommit(output: *Output) !void {
    if (!output.scene_output.?.needsFrame()) return;

    const wlr_output = output.wlr_output.?;

    var state = wlr.Output.State.init();
    defer state.finish();

    output.current.applyNoModeset(&state);

    if (!output.scene_output.?.buildState(&state, null)) return error.CommitFailed;

    if (!wlr_output.commitState(&state)) return error.CommitFailed;

    switch (server.lock_manager.state) {
        .unlocked => {
            if (output.lock_render_state != .unlocked) {
                output.lock_render_state = .pending_unlock;
            }
        },
        .locked => {
            assert(!server.scene.normal_tree.node.enabled);
            switch (output.lock_render_state) {
                .pending_unlock, .unlocked, .pending_blank, .pending_lock_surface => unreachable,
                .blanked, .lock_surface => {},
            }
        },
        .waiting_for_blank => {
            assert(!server.scene.normal_tree.node.enabled);
            if (output.lock_render_state != .blanked) {
                output.lock_render_state = .pending_blank;
            }
        },
        .waiting_for_lock_surfaces => {
            const lock_surface_mapped = blk: {
                if (server.lock_manager.lockSurfaceFromOutput(output)) |lock_surface| {
                    break :blk lock_surface.wlr_lock_surface.surface.mapped;
                } else {
                    break :blk false;
                }
            };
            if (lock_surface_mapped) {
                if (output.lock_render_state != .lock_surface) {
                    output.lock_render_state = .pending_lock_surface;
                }
            } else {
                if (output.lock_render_state != .unlocked) {
                    output.lock_render_state = .pending_unlock;
                }
            }
        },
    }
}

fn handlePresent(
    listener: *wl.Listener(*wlr.Output.event.Present),
    event: *wlr.Output.event.Present,
) void {
    const output: *Output = @fieldParentPtr("present", listener);
    if (!event.presented) {
        return;
    }
    switch (output.lock_render_state) {
        .pending_unlock => {
            assert(server.lock_manager.state != .locked);
            output.lock_render_state = .unlocked;
        },
        .unlocked => assert(server.lock_manager.state != .locked),
        .pending_blank => {
            output.lock_render_state = .blanked;
            if (server.lock_manager.state != .locked) {
                server.lock_manager.maybeLock();
            }
        },
        .pending_lock_surface => {
            output.lock_render_state = .lock_surface;
            if (server.lock_manager.state != .locked) {
                server.lock_manager.maybeLock();
            }
        },
        .blanked, .lock_surface => {},
    }
}
