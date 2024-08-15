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

const LayerSurface = @import("LayerSurface.zig");
const Layout = @import("Layout.zig");
const LayoutDemand = @import("LayoutDemand.zig");
const LockSurface = @import("LockSurface.zig");
const OutputStatus = @import("OutputStatus.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const View = @import("View.zig");
const Config = @import("Config.zig");

const log = std.log.scoped(.output);

pub const PendingState = struct {
    /// A bit field of focused tags
    tags: u32 = 1 << 0,
    /// The stack of views in focus/rendering order.
    ///
    /// This contains views that aren't currently visible because they do not
    /// match the tags of the output.
    ///
    /// This list is used to update the rendering order of nodes in the scene
    /// graph when the pending state is committed.
    focus_stack: wl.list.Head(View, .pending_focus_stack_link),
    /// The stack of views acted upon by window management commands such
    /// as focus-view, zoom, etc.
    ///
    /// This contains views that aren't currently visible because they do not
    /// match the tags of the output. This means that a filtered version of the
    /// list must be used for window management commands.
    ///
    /// This includes both floating/fullscreen views and those arranged in the layout.
    wm_stack: wl.list.Head(View, .pending_wm_stack_link),
};

wlr_output: *wlr.Output,
scene_output: *wlr.SceneOutput,

/// For Root.all_outputs
all_link: wl.list.Link,

/// For Root.active_outputs
active_link: wl.list.Link,

/// The area left for views and other layer surfaces after applying the
/// exclusive zones of exclusive layer surfaces.
/// TODO: this should be part of the output's State
usable_box: wlr.Box,

/// Scene node representing the entire output.
/// Position must be updated when the output is moved in the layout.
tree: *wlr.SceneTree,
normal_content: *wlr.SceneTree,
locked_content: *wlr.SceneTree,

/// Child nodes of normal_content
layers: struct {
    background_color_rect: *wlr.SceneRect,
    /// Background layer shell layer
    background: *wlr.SceneTree,
    /// Bottom layer shell layer
    bottom: *wlr.SceneTree,
    /// Views in the layout
    layout: *wlr.SceneTree,
    /// Floating views
    float: *wlr.SceneTree,
    /// Top layer shell layer
    top: *wlr.SceneTree,
    /// Fullscreen views
    fullscreen: *wlr.SceneTree,
    /// Overlay layer shell layer
    overlay: *wlr.SceneTree,
    /// Popups from xdg-shell and input-method-v2 clients.
    popups: *wlr.SceneTree,
},

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

/// The state of the output that is directly acted upon/modified through user input.
///
/// Pending state will be copied to the inflight state and communicated to clients
/// to be applied as a single atomic transaction across all clients as soon as any
/// in progress transaction has been completed.
///
/// Any time pending state is modified Root.applyPending() must be called
/// before yielding back to the event loop.
pending: PendingState,

/// The state most recently sent to the layout generator and clients.
/// This state is immutable until all clients have replied and the transaction
/// is completed, at which point this inflight state is copied to current.
inflight: struct {
    /// A bit field of focused tags
    tags: u32 = 1 << 0,
    /// See pending.focus_stack
    focus_stack: wl.list.Head(View, .inflight_focus_stack_link),
    /// See pending.wm_stack
    wm_stack: wl.list.Head(View, .inflight_wm_stack_link),
    /// The view to be made fullscreen, if any.
    fullscreen: ?*View = null,
    layout_demand: ?LayoutDemand = null,
},

/// The current state represented by the scene graph.
/// There is no need to have a current focus_stack/wm_stack copy as this
/// information is transferred from the inflight state to the scene graph
/// as an inflight transaction completes.
current: struct {
    /// A bit field of focused tags
    tags: u32 = 1 << 0,
    /// The currently fullscreen view, if any.
    fullscreen: ?*View = null,
} = .{},

/// Remembered version of tags (from last run)
previous_tags: u32 = 1 << 0,

attach_mode: ?Config.AttachMode = null,

/// List of all layouts
layouts: std.TailQueue(Layout) = .{},

/// The current layout namespace of the output. If null,
/// config.default_layout_namespace should be used instead.
/// Call handleLayoutNamespaceChange() after setting this.
layout_namespace: ?[]const u8 = null,

/// The last set layout name.
layout_name: ?[:0]const u8 = null,

/// Active layout, or null if views are un-arranged.
///
/// If null, views which are manually moved or resized (with the pointer or
/// or command) will not be automatically set to floating. Everything is
/// already floating, so this would be an unexpected change of a views state
/// the user will only notice once a layout affects the views. So instead we
/// "snap back" all manually moved views the next time a layout is active.
/// This is similar to dwms behvaviour. Note that this of course does not
/// affect already floating views.
layout: ?*Layout = null,

status: OutputStatus,

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

    const tree = try server.root.layers.outputs.createSceneTree();
    const normal_content = try tree.createSceneTree();

    output.* = .{
        .wlr_output = wlr_output,
        .scene_output = scene_output,
        .all_link = undefined,
        .active_link = undefined,
        .tree = tree,
        .normal_content = normal_content,
        .locked_content = try tree.createSceneTree(),
        .layers = .{
            .background_color_rect = try normal_content.createSceneRect(
                width,
                height,
                &server.config.background_color,
            ),
            .background = try normal_content.createSceneTree(),
            .bottom = try normal_content.createSceneTree(),
            .layout = try normal_content.createSceneTree(),
            .float = try normal_content.createSceneTree(),
            .top = try normal_content.createSceneTree(),
            .fullscreen = try normal_content.createSceneTree(),
            .overlay = try normal_content.createSceneTree(),
            .popups = try normal_content.createSceneTree(),
        },
        .pending = .{
            .focus_stack = undefined,
            .wm_stack = undefined,
        },
        .inflight = .{
            .focus_stack = undefined,
            .wm_stack = undefined,
        },
        .usable_box = .{
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
        },
        .status = undefined,
    };
    wlr_output.data = @intFromPtr(output);

    output.pending.focus_stack.init();
    output.pending.wm_stack.init();
    output.inflight.focus_stack.init();
    output.inflight.wm_stack.init();

    output.status.init();

    _ = try output.layers.fullscreen.createSceneRect(width, height, &[_]f32{ 0, 0, 0, 1.0 });
    output.layers.fullscreen.node.setEnabled(false);

    wlr_output.events.destroy.add(&output.destroy);
    wlr_output.events.request_state.add(&output.request_state);
    wlr_output.events.frame.add(&output.frame);
    wlr_output.events.present.add(&output.present);

    output.setTitle();

    output.active_link.init();
    server.root.all_outputs.append(output);

    output.handleEnableDisable();
}

pub fn layerSurfaceTree(output: Output, layer: zwlr.LayerShellV1.Layer) *wlr.SceneTree {
    const trees = [_]*wlr.SceneTree{
        output.layers.background,
        output.layers.bottom,
        output.layers.top,
        output.layers.overlay,
    };
    return trees[@intCast(@intFromEnum(layer))];
}

/// Arrange all layer surfaces of this output and adjust the usable area.
/// Will arrange views as well if the usable area changes.
/// Requires a call to Root.applyPending()
pub fn arrangeLayers(output: *Output) void {
    var full_box: wlr.Box = .{
        .x = 0,
        .y = 0,
        .width = undefined,
        .height = undefined,
    };
    output.wlr_output.effectiveResolution(&full_box.width, &full_box.height);

    // This box is modified as exclusive zones are applied
    var usable_box = full_box;

    // Ensure all exclusive zones are applied before arranging surfaces
    // without exclusive zones.
    output.sendLayerConfigures(full_box, &usable_box, .exclusive);
    output.sendLayerConfigures(full_box, &usable_box, .non_exclusive);

    output.usable_box = usable_box;
}

fn sendLayerConfigures(
    output: *Output,
    full_box: wlr.Box,
    usable_box: *wlr.Box,
    mode: enum { exclusive, non_exclusive },
) void {
    for ([_]zwlr.LayerShellV1.Layer{ .background, .bottom, .top, .overlay }) |layer| {
        const tree = output.layerSurfaceTree(layer);
        var it = tree.children.safeIterator(.forward);
        while (it.next()) |node| {
            assert(node.type == .tree);
            if (@as(?*SceneNodeData, @ptrFromInt(node.data))) |node_data| {
                const layer_surface = node_data.data.layer_surface;

                if (!layer_surface.wlr_layer_surface.initialized) continue;

                const exclusive = layer_surface.wlr_layer_surface.current.exclusive_zone > 0;
                if (exclusive != (mode == .exclusive)) {
                    continue;
                }

                {
                    var new_usable_box = usable_box.*;

                    layer_surface.scene_layer_surface.configure(&full_box, &new_usable_box);

                    // Clients can request bogus exclusive zones larger than the output
                    // dimensions and river must handle this gracefully. It seems reasonable
                    // to close layer shell clients that would cause the usable area of the
                    // output to become less than half the width/height of its full dimensions.
                    if (new_usable_box.width < @divTrunc(full_box.width, 2) or
                        new_usable_box.height < @divTrunc(full_box.height, 2))
                    {
                        layer_surface.wlr_layer_surface.destroy();
                        continue;
                    }

                    usable_box.* = new_usable_box;
                }

                layer_surface.popup_tree.node.setPosition(
                    layer_surface.scene_layer_surface.tree.node.x,
                    layer_surface.scene_layer_surface.tree.node.y,
                );
                layer_surface.scene_layer_surface.tree.node.subsurfaceTreeSetClip(&full_box);
            }
        }
    }
}

fn handleDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("destroy", listener);

    log.debug("output '{s}' destroyed", .{output.wlr_output.name});

    // Remove the destroyed output from root if it wasn't already removed
    server.root.deactivateOutput(output);

    assert(output.pending.focus_stack.empty());
    assert(output.pending.wm_stack.empty());
    assert(output.inflight.focus_stack.empty());
    assert(output.inflight.wm_stack.empty());
    assert(output.inflight.layout_demand == null);
    assert(output.layouts.len == 0);

    output.all_link.remove();

    output.destroy.link.remove();
    output.request_state.link.remove();
    output.frame.link.remove();
    output.present.link.remove();

    output.tree.node.destroy();

    if (output.layout_namespace) |namespace| util.gpa.free(namespace);

    output.wlr_output.data = 0;

    util.gpa.destroy(output);

    server.root.handleOutputConfigChange() catch std.log.err("out of memory", .{});

    server.root.applyPending();
}

fn handleRequestState(listener: *wl.Listener(*wlr.Output.event.RequestState), event: *wlr.Output.event.RequestState) void {
    const output: *Output = @fieldParentPtr("request_state", listener);

    output.applyState(event.state) catch {
        log.err("failed to commit requested state", .{});
        return;
    };

    server.root.applyPending();
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
        output.updateBackgroundRect();
        output.arrangeLayers();
        server.lock_manager.updateLockSurfaceSize(output);
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
    // We can't assert the current state of normal_content/locked_content
    // here as this output may be newly created.
    if (output.wlr_output.enabled) {
        switch (server.lock_manager.state) {
            .unlocked => {
                assert(output.lock_render_state == .blanked);
                output.normal_content.node.setEnabled(true);
                output.locked_content.node.setEnabled(false);
            },
            .waiting_for_lock_surfaces, .waiting_for_blank, .locked => {
                assert(output.lock_render_state == .blanked);
                output.normal_content.node.setEnabled(false);
                output.locked_content.node.setEnabled(true);
            },
        }
    } else {
        // Disabling and re-enabling an output always blanks it.
        output.lock_render_state = .blanked;
        output.normal_content.node.setEnabled(false);
        output.locked_content.node.setEnabled(true);
    }
}

pub fn updateBackgroundRect(output: *Output) void {
    var width: c_int = undefined;
    var height: c_int = undefined;
    output.wlr_output.effectiveResolution(&width, &height);
    output.layers.background_color_rect.setSize(width, height);

    var it = output.layers.fullscreen.children.iterator(.forward);
    const fullscreen_background: *wlr.SceneRect = @fieldParentPtr("node", it.next().?);
    fullscreen_background.setSize(width, height);
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
    var state = wlr.Output.State.init();
    defer state.finish();

    if (!scene_output.buildState(&state, null)) return error.CommitFailed;

    if (output.gamma_dirty) {
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
    }

    if (output.current.fullscreen) |fullscreen| {
        if (fullscreen.allowTearing()) {
            state.tearing_page_flip = true;
            if (!output.wlr_output.testState(&state)) {
                log.debug("tearing page flip test failed for {s}, retrying without tearing", .{
                    output.wlr_output.name,
                });
                state.tearing_page_flip = false;
            }
        }
    }

    if (!output.wlr_output.commitState(&state)) return error.CommitFailed;

    output.gamma_dirty = false;

    if (server.lock_manager.state == .locked or
        (server.lock_manager.state == .waiting_for_lock_surfaces and output.locked_content.node.enabled) or
        server.lock_manager.state == .waiting_for_blank)
    {
        assert(!output.normal_content.node.enabled);
        assert(output.locked_content.node.enabled);

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

pub fn handleLayoutNamespaceChange(output: *Output) void {
    // The user changed the layout namespace of this output. Try to find a
    // matching layout.
    var it = output.layouts.first;
    output.layout = while (it) |node| : (it = node.next) {
        if (mem.eql(u8, output.layoutNamespace(), node.data.namespace)) break &node.data;
    } else null;
    server.root.applyPending();
}

pub fn layoutNamespace(output: Output) []const u8 {
    return output.layout_namespace orelse server.config.default_layout_namespace;
}

pub fn attachMode(output: Output) Config.AttachMode {
    return output.attach_mode orelse server.config.default_attach_mode;
}
