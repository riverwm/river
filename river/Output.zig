// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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

const server = &@import("main.zig").server;
const util = @import("util.zig");

const LockSurface = @import("LockSurface.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Window = @import("Window.zig");
const Config = @import("Config.zig");

const log = std.log.scoped(.output);

wlr_output: *wlr.Output,
scene_output: *wlr.SceneOutput,

/// For Root.all_outputs
all_link: wl.list.Link,

/// For Root.active_outputs
active_link: wl.list.Link,

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

/// Set to true if a gamma control client makes a set gamma request.
/// This request is handled while rendering the next frame in handleFrame().
gamma_dirty: bool = false,

destroy: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleDestroy),
request_state: wl.Listener(*wlr.Output.event.RequestState) = wl.Listener(*wlr.Output.event.RequestState).init(handleRequestState),
frame: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleFrame),
present: wl.Listener(*wlr.Output.event.Present) = wl.Listener(*wlr.Output.event.Present).init(handlePresent),

pub fn create(wlr_output: *wlr.Output) !void {
    const output = try util.gpa.create(Output);
    errdefer util.gpa.destroy(output);

    if (!wlr_output.initRender(server.allocator, server.renderer)) return error.InitRenderFailed;

    // If no standard mode for the output works we can't enable the output automatically.
    // It will stay disabled unless the user configures a custom mode which works.
    //
    // For the Wayland backend, the list of modes will be empty and it is possible to
    // enable the output without setting a mode.
    {
        var state = wlr.Output.State.init();
        defer state.finish();

        state.setEnabled(true);

        if (wlr_output.preferredMode()) |preferred_mode| {
            state.setMode(preferred_mode);
        }

        if (!wlr_output.commitState(&state)) {
            log.err("initial output commit with preferred mode failed, trying all modes", .{});

            // It is important to try other modes if the preferred mode fails
            // which is reported to be helpful in practice with e.g. multiple
            // high resolution monitors connected through a usb dock.
            var it = wlr_output.modes.iterator(.forward);
            while (it.next()) |mode| {
                state.setMode(mode);
                if (wlr_output.commitState(&state)) {
                    log.info("initial output commit succeeded with mode {}x{}@{}mHz", .{
                        mode.width,
                        mode.height,
                        mode.refresh,
                    });
                    break;
                } else {
                    log.err("initial output commit failed with mode {}x{}@{}mHz", .{
                        mode.width,
                        mode.height,
                        mode.refresh,
                    });
                }
            }
        }
    }

    var width: c_int = undefined;
    var height: c_int = undefined;
    wlr_output.effectiveResolution(&width, &height);

    const scene_output = try server.root.scene.createSceneOutput(wlr_output);

    output.* = .{
        .wlr_output = wlr_output,
        .scene_output = scene_output,
        .all_link = undefined,
        .active_link = undefined,
    };
    wlr_output.data = @intFromPtr(output);

    wlr_output.events.destroy.add(&output.destroy);
    wlr_output.events.request_state.add(&output.request_state);
    wlr_output.events.frame.add(&output.frame);
    wlr_output.events.present.add(&output.present);

    output.setTitle();

    output.active_link.init();
    server.root.all_outputs.append(output);

    output.handleEnableDisable();
}

fn handleDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("destroy", listener);

    log.debug("output '{s}' destroyed", .{output.wlr_output.name});

    // Remove the destroyed output from root if it wasn't already removed
    server.root.deactivateOutput(output);

    output.all_link.remove();

    output.destroy.link.remove();
    output.request_state.link.remove();
    output.frame.link.remove();
    output.present.link.remove();

    output.wlr_output.data = 0;

    util.gpa.destroy(output);

    server.root.handleOutputConfigChange() catch std.log.err("out of memory", .{});

    server.wm.dirtyPending();
}

fn handleRequestState(listener: *wl.Listener(*wlr.Output.event.RequestState), event: *wlr.Output.event.RequestState) void {
    const output: *Output = @fieldParentPtr("request_state", listener);

    output.applyState(event.state) catch {
        log.err("failed to commit requested state", .{});
        return;
    };

    server.wm.dirtyPending();
}

// TODO double buffer output state changes for frame perfection and cleaner code.
// Schedule a frame and commit in the frame handler.
// Get rid of this function.
pub fn applyState(output: *Output, state: *wlr.Output.State) error{CommitFailed}!void {

    // We need to be precise about this state change to make assertions
    // in updateLockRenderStateOnEnableDisable() possible.
    const enable_state_change = state.committed.enabled and
        (state.enabled != output.wlr_output.enabled);

    if (!output.wlr_output.commitState(state)) {
        return error.CommitFailed;
    }

    if (enable_state_change) {
        output.handleEnableDisable();
    }

    if (state.committed.mode) {
        if (server.lock_manager.lockSurfaceFromOutput(output)) |s| s.configure();
    }
}

fn handleEnableDisable(output: *Output) void {
    output.updateLockRenderStateOnEnableDisable();
    output.gamma_dirty = true;

    if (output.wlr_output.enabled) {
        // Add the output to root.active_outputs and the output layout if it has not
        // already been added.
        server.root.activateOutput(output);
    } else {
        server.root.deactivateOutput(output);
    }
}

pub fn updateLockRenderStateOnEnableDisable(output: *Output) void {
    if (output.wlr_output.enabled) {
        assert(output.lock_render_state == .blanked);
    } else {
        // Disabling and re-enabling an output always blanks it.
        output.lock_render_state = .blanked;
    }
}

fn handleFrame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("frame", listener);
    const scene_output = server.root.scene.getSceneOutput(output.wlr_output).?;

    // TODO this should probably be retried on failure
    output.renderAndCommit(scene_output) catch |err| switch (err) {
        error.OutOfMemory => log.err("out of memory", .{}),
        error.CommitFailed => log.err("output commit failed for {s}", .{output.wlr_output.name}),
    };

    var now: posix.timespec = undefined;
    posix.clock_gettime(posix.CLOCK.MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
    scene_output.sendFrameDone(&now);
}

fn renderAndCommit(output: *Output, scene_output: *wlr.SceneOutput) !void {
    if (output.gamma_dirty) {
        var state = wlr.Output.State.init();
        defer state.finish();

        const control = server.root.gamma_control_manager.getControl(output.wlr_output);
        if (!wlr.GammaControlV1.apply(control, &state)) return error.OutOfMemory;

        if (!output.wlr_output.testState(&state)) {
            wlr.GammaControlV1.sendFailedAndDestroy(control);
            state.clearGammaLut();
            // If the backend does not support gamma LUTs it will reject any
            // state with the gamma LUT committed bit set even if the state
            // has a null LUT. The wayland backend for example has this behavior.
            state.committed.gamma_lut = false;
        }

        if (!scene_output.buildState(&state, null)) return error.CommitFailed;

        if (!output.wlr_output.commitState(&state)) return error.CommitFailed;

        output.gamma_dirty = false;
    } else {
        if (!scene_output.commit(null)) return error.CommitFailed;
    }

    const lock_surface_mapped = blk: {
        if (server.lock_manager.lockSurfaceFromOutput(output)) |lock_surface| {
            break :blk lock_surface.wlr_lock_surface.surface.mapped;
        } else {
            break :blk false;
        }
    };

    if (server.lock_manager.state == .locked or
        (server.lock_manager.state == .waiting_for_lock_surfaces and lock_surface_mapped) or
        server.lock_manager.state == .waiting_for_blank)
    {
        assert(!server.root.normal_tree.node.enabled);
        assert(server.root.locked_tree.node.enabled);

        switch (server.lock_manager.state) {
            .unlocked => unreachable,
            .locked => switch (output.lock_render_state) {
                .pending_unlock, .unlocked, .pending_blank, .pending_lock_surface => unreachable,
                .blanked, .lock_surface => {},
            },
            .waiting_for_blank => {
                if (output.lock_render_state != .blanked) {
                    output.lock_render_state = .pending_blank;
                }
            },
            .waiting_for_lock_surfaces => {
                if (output.lock_render_state != .lock_surface) {
                    output.lock_render_state = .pending_lock_surface;
                }
            },
        }
    } else {
        if (output.lock_render_state != .unlocked) {
            output.lock_render_state = .pending_unlock;
        }
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
        .pending_blank, .pending_lock_surface => {
            output.lock_render_state = switch (output.lock_render_state) {
                .pending_blank => .blanked,
                .pending_lock_surface => .lock_surface,
                .pending_unlock, .unlocked, .blanked, .lock_surface => unreachable,
            };

            if (server.lock_manager.state != .locked) {
                server.lock_manager.maybeLock();
            }
        },
        .blanked, .lock_surface => {},
    }
}

fn setTitle(output: Output) void {
    const title = fmt.allocPrintZ(util.gpa, "river - {s}", .{output.wlr_output.name}) catch return;
    defer util.gpa.free(title);
    if (output.wlr_output.isWl()) {
        output.wlr_output.wlSetTitle(title);
    } else if (wlr.config.has_x11_backend and output.wlr_output.isX11()) {
        output.wlr_output.x11SetTitle(title);
    }
}
