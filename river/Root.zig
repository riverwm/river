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

const Root = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const zwlr = @import("wayland").server.zwlr;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const DragIcon = @import("DragIcon.zig");
const LayerSurface = @import("LayerSurface.zig");
const LockSurface = @import("LockSurface.zig");
const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const View = @import("View.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");

scene: *wlr.Scene,
/// All windows, status bars, drowdown menus, etc. that can recieve pointer events and similar.
interactive_content: *wlr.SceneTree,
/// Drag icons, which cannot recieve e.g. pointer events and are therefore kept in a separate tree.
drag_icons: *wlr.SceneTree,

/// All direct children of the interactive_content scene node
layers: struct {
    /// Parent tree for output trees which have their position updated when
    /// outputs are moved in the layout.
    outputs: *wlr.SceneTree,
    /// Xwayland override redirect windows are a legacy wart that decide where
    /// to place themselves in layout coordinates. Unfortunately this is how
    /// X11 decided to make dropdown menus and the like possible.
    override_redirect: if (build_options.xwayland) *wlr.SceneTree else void,
},

/// This is kind of like an imaginary output where views start and end their life.
hidden: struct {
    /// This tree is always disabled.
    tree: *wlr.SceneTree,

    pending: struct {
        focus_stack: wl.list.Head(View, .pending_focus_stack_link),
        wm_stack: wl.list.Head(View, .pending_wm_stack_link),
    },

    inflight: struct {
        focus_stack: wl.list.Head(View, .inflight_focus_stack_link),
        wm_stack: wl.list.Head(View, .inflight_wm_stack_link),
    },
},

/// This is used to store views and tags when no actual outputs are available.
/// This must be separate from hidden to ensure we don't mix views that are
/// in the process of being mapped/unmapped with the mapped views in these lists.
/// There is no need for inflight lists, instead the inflight links of views are
/// remove()'d from their current list and init()'d so they may be remove()'d again
/// when an output becomes available and they are moved to the output's inflight lists.
fallback_pending: Output.PendingState,

views: wl.list.Head(View, .link),

new_output: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleNewOutput),

output_layout: *wlr.OutputLayout,
layout_change: wl.Listener(*wlr.OutputLayout) = wl.Listener(*wlr.OutputLayout).init(handleLayoutChange),

presentation: *wlr.Presentation,
xdg_output_manager: *wlr.XdgOutputManagerV1,

output_manager: *wlr.OutputManagerV1,
manager_apply: wl.Listener(*wlr.OutputConfigurationV1) =
    wl.Listener(*wlr.OutputConfigurationV1).init(handleManagerApply),
manager_test: wl.Listener(*wlr.OutputConfigurationV1) =
    wl.Listener(*wlr.OutputConfigurationV1).init(handleManagerTest),

power_manager: *wlr.OutputPowerManagerV1,
power_manager_set_mode: wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode) =
    wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode).init(handlePowerManagerSetMode),

gamma_control_manager: *wlr.GammaControlManagerV1,
gamma_control_set_gamma: wl.Listener(*wlr.GammaControlManagerV1.event.SetGamma) =
    wl.Listener(*wlr.GammaControlManagerV1.event.SetGamma).init(handleSetGamma),

/// A list of all outputs
all_outputs: wl.list.Head(Output, .all_link),

/// A list of all active outputs (any one that can be interacted with, even if
/// it's turned off by dpms)
active_outputs: wl.list.Head(Output, .active_link),

/// Number of layout demands before sending configures to clients.
inflight_layout_demands: u32 = 0,
/// Number of inflight configures sent in the current transaction.
inflight_configures: u32 = 0,
transaction_timeout: *wl.EventSource,
/// Set to true if applyPending() is called while a transaction is inflight.
/// If true when a transaction completes, causes applyPending() to be called again.
pending_state_dirty: bool = false,

pub fn init(root: *Root) !void {
    const output_layout = try wlr.OutputLayout.create();
    errdefer output_layout.destroy();

    const scene = try wlr.Scene.create();
    errdefer scene.tree.node.destroy();

    const interactive_content = try scene.tree.createSceneTree();
    const drag_icons = try scene.tree.createSceneTree();
    const hidden_tree = try scene.tree.createSceneTree();
    hidden_tree.node.setEnabled(false);

    const outputs = try interactive_content.createSceneTree();
    const override_redirect = if (build_options.xwayland) try interactive_content.createSceneTree();

    const presentation = try wlr.Presentation.create(server.wl_server, server.backend);
    scene.setPresentation(presentation);

    const event_loop = server.wl_server.getEventLoop();
    const transaction_timeout = try event_loop.addTimer(*Root, handleTransactionTimeout, root);
    errdefer transaction_timeout.remove();

    root.* = .{
        .scene = scene,
        .interactive_content = interactive_content,
        .drag_icons = drag_icons,
        .layers = .{
            .outputs = outputs,
            .override_redirect = override_redirect,
        },
        .hidden = .{
            .tree = hidden_tree,
            .pending = .{
                .focus_stack = undefined,
                .wm_stack = undefined,
            },
            .inflight = .{
                .focus_stack = undefined,
                .wm_stack = undefined,
            },
        },
        .fallback_pending = .{
            .focus_stack = undefined,
            .wm_stack = undefined,
        },
        .views = undefined,
        .output_layout = output_layout,
        .all_outputs = undefined,
        .active_outputs = undefined,

        .presentation = presentation,
        .xdg_output_manager = try wlr.XdgOutputManagerV1.create(server.wl_server, output_layout),
        .output_manager = try wlr.OutputManagerV1.create(server.wl_server),
        .power_manager = try wlr.OutputPowerManagerV1.create(server.wl_server),
        .gamma_control_manager = try wlr.GammaControlManagerV1.create(server.wl_server),
        .transaction_timeout = transaction_timeout,
    };
    root.hidden.pending.focus_stack.init();
    root.hidden.pending.wm_stack.init();
    root.hidden.inflight.focus_stack.init();
    root.hidden.inflight.wm_stack.init();

    root.fallback_pending.focus_stack.init();
    root.fallback_pending.wm_stack.init();

    root.views.init();
    root.all_outputs.init();
    root.active_outputs.init();

    server.backend.events.new_output.add(&root.new_output);
    root.output_manager.events.apply.add(&root.manager_apply);
    root.output_manager.events.@"test".add(&root.manager_test);
    root.output_layout.events.change.add(&root.layout_change);
    root.power_manager.events.set_mode.add(&root.power_manager_set_mode);
    root.gamma_control_manager.events.set_gamma.add(&root.gamma_control_set_gamma);
}

pub fn deinit(root: *Root) void {
    root.output_layout.destroy();
    root.transaction_timeout.remove();
}

pub const AtResult = struct {
    node: *wlr.SceneNode,
    surface: ?*wlr.Surface,
    sx: f64,
    sy: f64,
    data: SceneNodeData.Data,
};

/// Return information about what is currently rendered in the interactive_content
/// tree at the given layout coordinates, taking surface input regions into account.
pub fn at(root: Root, lx: f64, ly: f64) ?AtResult {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    const node = root.interactive_content.node.at(lx, ly, &sx, &sy) orelse return null;

    const surface: ?*wlr.Surface = blk: {
        if (node.type == .buffer) {
            const scene_buffer = wlr.SceneBuffer.fromNode(node);
            if (wlr.SceneSurface.tryFromBuffer(scene_buffer)) |scene_surface| {
                break :blk scene_surface.surface;
            }
        }
        break :blk null;
    };

    if (SceneNodeData.fromNode(node)) |scene_node_data| {
        return .{
            .node = node,
            .surface = surface,
            .sx = sx,
            .sy = sy,
            .data = scene_node_data.data,
        };
    } else {
        return null;
    }
}

fn handleNewOutput(_: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const log = std.log.scoped(.output_manager);

    log.debug("new output {s}", .{wlr_output.name});

    Output.create(wlr_output) catch |err| {
        switch (err) {
            error.OutOfMemory => log.err("out of memory", .{}),
            error.InitRenderFailed => log.err("failed to initialize renderer for output {s}", .{wlr_output.name}),
        }
        wlr_output.destroy();
        return;
    };

    server.root.handleOutputConfigChange() catch log.err("out of memory", .{});

    server.input_manager.reconfigureDevices();
}

/// Remove the output from root.active_outputs and the output layout.
/// Evacuate views if necessary.
pub fn deactivateOutput(root: *Root, output: *Output) void {
    {
        // If the output has already been removed, do nothing
        var it = root.active_outputs.iterator(.forward);
        while (it.next()) |o| {
            if (o == output) break;
        } else return;
    }

    root.output_layout.remove(output.wlr_output);
    output.tree.node.setEnabled(false);

    output.active_link.remove();
    output.active_link.init();

    {
        var it = output.inflight.focus_stack.safeIterator(.forward);
        while (it.next()) |view| {
            view.inflight.output = null;
            view.current.output = null;

            view.tree.node.reparent(root.hidden.tree);
            view.popup_tree.node.reparent(root.hidden.tree);

            view.inflight_focus_stack_link.remove();
            view.inflight_focus_stack_link.init();

            view.inflight_wm_stack_link.remove();
            view.inflight_wm_stack_link.init();

            if (view.inflight_transaction) {
                view.commitTransaction();
            }

            // Store outputs connector name so that views can be moved back to
            // reconnecting outputs. Skip if there is already a connector name
            // stored to better handle the case of multiple outputs being
            // removed sequentially.
            if (view.output_before_evac == null) {
                const name = mem.span(output.wlr_output.name);
                view.output_before_evac = util.gpa.dupe(u8, name) catch null;
            }
        }
    }
    // Use the first output in the list as fallback. If the last real output
    // is being removed, store the views in Root.fallback_pending.
    const fallback_output = blk: {
        var it = root.active_outputs.iterator(.forward);
        break :blk it.next();
    };
    if (fallback_output) |fallback| {
        var it = output.pending.focus_stack.safeIterator(.reverse);
        while (it.next()) |view| view.setPendingOutput(fallback);
    } else {
        var it = output.pending.focus_stack.iterator(.forward);
        while (it.next()) |view| view.pending.output = null;
        root.fallback_pending.focus_stack.prependList(&output.pending.focus_stack);
        root.fallback_pending.wm_stack.prependList(&output.pending.wm_stack);
        // Store the focused output tags if we are hotplugged down to
        // 0 real outputs so they can be restored on gaining a new output.
        root.fallback_pending.tags = output.pending.tags;
    }

    // Close all layer surfaces on the removed output
    for ([_]zwlr.LayerShellV1.Layer{ .overlay, .top, .bottom, .background }) |layer| {
        const tree = output.layerSurfaceTree(layer);
        var it = tree.children.safeIterator(.forward);
        while (it.next()) |scene_node| {
            assert(scene_node.type == .tree);
            if (@as(?*SceneNodeData, @ptrFromInt(scene_node.data))) |node_data| {
                node_data.data.layer_surface.wlr_layer_surface.destroy();
            }
        }
    }

    // If any seat has the removed output focused, focus the fallback one
    var seat_it = server.input_manager.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        const seat = &seat_node.data;
        if (seat.focused_output == output) {
            seat.focusOutput(fallback_output);
        }
    }

    output.status.deinit();
    output.status.init();

    if (output.inflight.layout_demand) |layout_demand| {
        layout_demand.deinit();
        output.inflight.layout_demand = null;
        root.notifyLayoutDemandDone();
    }
    while (output.layouts.first) |node| node.data.destroy();

    // We must call reconfigureDevices here to unmap devices that might be mapped to this output
    // in order to prevent a segfault in wlroots.
    server.input_manager.reconfigureDevices();
}

/// Add the output to root.active_outputs and the output layout if it has not
/// already been added.
pub fn activateOutput(root: *Root, output: *Output) void {
    {
        // If we have already added the output, do nothing and return
        var it = root.active_outputs.iterator(.forward);
        while (it.next()) |o| if (o == output) return;
    }

    const first = root.active_outputs.empty();

    root.active_outputs.append(output);

    // This arranges outputs from left-to-right in the order they appear. The
    // wlr-output-management protocol may be used to modify this arrangement.
    // This also creates a wl_output global which is advertised to clients.
    _ = root.output_layout.addAuto(output.wlr_output) catch {
        // This would currently be very awkward to handle well and this output
        // handling code needs to be heavily refactored soon anyways for double
        // buffered state application as part of the transaction system.
        // In any case, wlroots 0.16 would have crashed here, the error is only
        // possible to handle after updating to 0.17.
        @panic("TODO handle allocation failure here");
    };

    // If we previously had no outputs, move all views to the new output and focus it.
    if (first) {
        const log = std.log.scoped(.output_manager);
        log.debug("moving views from fallback stacks to new output", .{});

        output.pending.tags = root.fallback_pending.tags;
        {
            var it = root.fallback_pending.wm_stack.safeIterator(.reverse);
            while (it.next()) |view| view.setPendingOutput(output);
        }
        {
            // Focus the new output with all seats
            var it = server.input_manager.seats.first;
            while (it) |seat_node| : (it = seat_node.next) {
                const seat = &seat_node.data;
                seat.focusOutput(output);
            }
        }
    } else {
        // Otherwise check if any views were previously evacuated from an output
        // with the same (connector-)name and move them back.
        var it = root.views.iterator(.forward);
        while (it.next()) |view| {
            const name = view.output_before_evac orelse continue;
            if (mem.eql(u8, name, mem.span(output.wlr_output.name))) {
                if (view.pending.output != output) {
                    view.setPendingOutput(output);
                }
                util.gpa.free(name);
                view.output_before_evac = null;
            }
        }
    }
    assert(root.fallback_pending.focus_stack.empty());
    assert(root.fallback_pending.wm_stack.empty());
}

/// Trigger asynchronous application of pending state for all outputs and views.
/// Changes will not be applied to the scene graph until the layout generator
/// generates a new layout for all outputs and all affected clients ack a
/// configure and commit a new buffer.
pub fn applyPending(root: *Root) void {
    {
        // Changes to the pending state may require a focus update to keep
        // state consistent. Instead of having focus(null) calls spread all
        // around the codebase and risk forgetting one, always ensure focus
        // state is synchronized here.
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) node.data.focus(null);
    }

    // If there is already a transaction inflight, wait until it completes.
    if (root.inflight_layout_demands > 0 or root.inflight_configures > 0) {
        root.pending_state_dirty = true;
        return;
    }
    root.pending_state_dirty = false;

    {
        var it = root.hidden.pending.focus_stack.iterator(.forward);
        while (it.next()) |view| {
            assert(view.pending.output == null);
            view.inflight.output = null;
            view.inflight_focus_stack_link.remove();
            root.hidden.inflight.focus_stack.append(view);
        }
    }

    {
        var it = root.hidden.pending.wm_stack.iterator(.forward);
        while (it.next()) |view| {
            view.inflight_wm_stack_link.remove();
            root.hidden.inflight.wm_stack.append(view);
        }
    }

    {
        var output_it = root.active_outputs.iterator(.forward);
        while (output_it.next()) |output| {
            // Iterate the focus stack in order to ensure the currently focused/most
            // recently focused view that requests fullscreen is given fullscreen.
            output.inflight.fullscreen = null;
            {
                var it = output.pending.focus_stack.iterator(.forward);
                while (it.next()) |view| {
                    assert(view.pending.output == output);

                    if (view.current.float and !view.pending.float) {
                        // If switching from float to non-float, save the dimensions.
                        view.float_box = view.current.box;
                    } else if (!view.current.float and view.pending.float) {
                        // If switching from non-float to float, apply the saved float dimensions.
                        view.pending.box = view.float_box;
                        view.pending.clampToOutput();
                    }

                    if (!view.current.fullscreen and view.pending.fullscreen) {
                        view.post_fullscreen_box = view.pending.box;
                        view.pending.box = .{ .x = 0, .y = 0, .width = undefined, .height = undefined };
                        output.wlr_output.effectiveResolution(&view.pending.box.width, &view.pending.box.height);
                    } else if (view.current.fullscreen and !view.pending.fullscreen) {
                        view.pending.box = view.post_fullscreen_box;
                        view.pending.clampToOutput();
                    }

                    if (output.inflight.fullscreen == null and view.pending.fullscreen and
                        view.pending.tags & output.pending.tags != 0)
                    {
                        output.inflight.fullscreen = view;
                    }

                    view.inflight_focus_stack_link.remove();
                    output.inflight.focus_stack.append(view);

                    view.inflight = view.pending;
                }
            }

            {
                var it = output.pending.wm_stack.iterator(.forward);
                while (it.next()) |view| {
                    view.inflight_wm_stack_link.remove();
                    output.inflight.wm_stack.append(view);
                }
            }

            output.inflight.tags = output.pending.tags;
        }
    }

    {
        // Layout demands can't be sent until after the inflight stacks of
        // all outputs have been updated.
        var output_it = root.active_outputs.iterator(.forward);
        while (output_it.next()) |output| {
            assert(output.inflight.layout_demand == null);
            if (output.layout) |layout| {
                var layout_count: u32 = 0;
                {
                    var it = output.inflight.wm_stack.iterator(.forward);
                    while (it.next()) |view| {
                        if (!view.inflight.float and !view.inflight.fullscreen and
                            view.inflight.tags & output.inflight.tags != 0)
                        {
                            layout_count += 1;
                        }
                    }
                }

                if (layout_count > 0) {
                    // TODO don't do this if the count has not changed
                    layout.startLayoutDemand(layout_count);
                }
            }
        }
    }

    {
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) {
            const cursor = &node.data.cursor;

            switch (cursor.mode) {
                .passthrough, .down => {},
                inline .move, .resize => |data| {
                    if (data.view.inflight.output == null or
                        data.view.inflight.tags & data.view.inflight.output.?.inflight.tags == 0 or
                        (!data.view.inflight.float and data.view.inflight.output.?.layout != null) or
                        data.view.inflight.fullscreen)
                    {
                        cursor.mode = .passthrough;
                        data.view.pending.resizing = false;
                        data.view.inflight.resizing = false;
                    }
                },
            }

            cursor.inflight_mode = cursor.mode;
        }
    }

    if (root.inflight_layout_demands == 0) {
        root.sendConfigures();
    }
}

/// This function is used to inform the transaction system that a layout demand
/// has either been completed or timed out. If it was the last pending layout
/// demand in the current sequence, a transaction is started.
pub fn notifyLayoutDemandDone(root: *Root) void {
    root.inflight_layout_demands -= 1;
    if (root.inflight_layout_demands == 0) {
        root.sendConfigures();
    }
}

fn sendConfigures(root: *Root) void {
    assert(root.inflight_layout_demands == 0);
    assert(root.inflight_configures == 0);

    // Iterate over all views of all outputs
    var output_it = root.active_outputs.iterator(.forward);
    while (output_it.next()) |output| {
        var focus_stack_it = output.inflight.focus_stack.iterator(.forward);
        while (focus_stack_it.next()) |view| {
            assert(!view.inflight_transaction);
            view.inflight_transaction = true;

            // This can happen if a view is unmapped while a layout demand including it is inflight
            // If a view has been unmapped, don't send it a configure.
            if (!view.mapped) continue;

            if (view.configure()) {
                root.inflight_configures += 1;

                view.saveSurfaceTree();
                view.sendFrameDone();
            }
        }
    }

    if (root.inflight_configures > 0) {
        std.log.scoped(.transaction).debug("started transaction with {} pending configure(s)", .{
            root.inflight_configures,
        });

        root.transaction_timeout.timerUpdate(100) catch {
            std.log.scoped(.transaction).err("failed to update timer", .{});
            root.commitTransaction();
        };
    } else {
        root.commitTransaction();
    }
}

fn handleTransactionTimeout(root: *Root) c_int {
    assert(root.inflight_layout_demands == 0);

    std.log.scoped(.transaction).err("timeout occurred, some imperfect frames may be shown", .{});

    root.inflight_configures = 0;
    root.commitTransaction();

    return 0;
}

pub fn notifyConfigured(root: *Root) void {
    assert(root.inflight_layout_demands == 0);

    root.inflight_configures -= 1;
    if (root.inflight_configures == 0) {
        // Disarm the timer, as we didn't timeout
        root.transaction_timeout.timerUpdate(0) catch std.log.scoped(.transaction).err("error disarming timer", .{});
        root.commitTransaction();
    }
}

/// Apply the inflight state and drop stashed buffers. This means that
/// the next frame drawn will be the post-transaction state of the
/// layout. Should only be called after all clients have configured for
/// the new layout. If called early imperfect frames may be drawn.
fn commitTransaction(root: *Root) void {
    assert(root.inflight_layout_demands == 0);
    assert(root.inflight_configures == 0);

    std.log.scoped(.transaction).debug("commiting transaction", .{});

    {
        var it = root.hidden.inflight.focus_stack.safeIterator(.forward);
        while (it.next()) |view| {
            assert(view.inflight.output == null);
            view.current.output = null;

            view.tree.node.reparent(root.hidden.tree);
            view.popup_tree.node.reparent(root.hidden.tree);
        }
    }

    var output_it = root.active_outputs.iterator(.forward);
    while (output_it.next()) |output| {
        if (output.inflight.tags != output.current.tags) {
            std.log.scoped(.output).debug(
                "changing current focus: {b:0>10} to {b:0>10}",
                .{ output.current.tags, output.inflight.tags },
            );
        }
        output.current.tags = output.inflight.tags;

        var focus_stack_it = output.inflight.focus_stack.iterator(.forward);
        while (focus_stack_it.next()) |view| {
            assert(view.inflight.output == output);

            if (view.current.output != view.inflight.output or
                (output.current.fullscreen == view and output.inflight.fullscreen != view))
            {
                if (view.inflight.float) {
                    view.tree.node.reparent(output.layers.float);
                } else {
                    view.tree.node.reparent(output.layers.layout);
                }
                view.popup_tree.node.reparent(output.layers.popups);
            }

            if (view.current.float != view.inflight.float) {
                if (view.inflight.float) {
                    view.tree.node.reparent(output.layers.float);
                } else {
                    view.tree.node.reparent(output.layers.layout);
                }
            }

            view.commitTransaction();

            const enabled = view.current.tags & output.current.tags != 0;
            view.tree.node.setEnabled(enabled);
            view.popup_tree.node.setEnabled(enabled);
            if (output.inflight.fullscreen != view) {
                // TODO this approach for syncing the order will likely cause over-damaging.
                view.tree.node.lowerToBottom();
            }
        }

        if (output.inflight.fullscreen != output.current.fullscreen) {
            if (output.inflight.fullscreen) |view| {
                assert(view.inflight.output == output);
                assert(view.current.output == output);
                view.tree.node.reparent(output.layers.fullscreen);
            }
            output.current.fullscreen = output.inflight.fullscreen;
            output.layers.fullscreen.node.setEnabled(output.current.fullscreen != null);
        }

        output.status.handleTransactionCommit(output);
    }

    {
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) node.data.cursor.updateState();
    }

    {
        // This must be done after updating cursor state in case the view was the target of move/resize.
        var it = root.hidden.inflight.focus_stack.safeIterator(.forward);
        while (it.next()) |view| {
            if (view.destroying) view.destroy();
        }
    }

    server.idle_inhibit_manager.checkActive();

    if (root.pending_state_dirty) {
        root.applyPending();
    }
}

// We need this listener to deal with outputs that have their position auto-configured
// by the wlr_output_layout.
fn handleLayoutChange(listener: *wl.Listener(*wlr.OutputLayout), _: *wlr.OutputLayout) void {
    const root = @fieldParentPtr(Root, "layout_change", listener);

    root.handleOutputConfigChange() catch std.log.err("out of memory", .{});
}

/// Sync up the output scene node state with the output_layout and
/// send the current output configuration to all wlr-output-manager clients.
pub fn handleOutputConfigChange(root: *Root) !void {
    const config = try wlr.OutputConfigurationV1.create();
    // this destroys all associated config heads as well
    errdefer config.destroy();

    var it = root.all_outputs.iterator(.forward);
    while (it.next()) |output| {
        // If the output is not part of the layout (and thus disabled)
        // the box will be zeroed out.
        var box: wlr.Box = undefined;
        root.output_layout.getBox(output.wlr_output, &box);

        output.tree.node.setEnabled(!box.empty());
        output.tree.node.setPosition(box.x, box.y);
        output.scene_output.setPosition(box.x, box.y);

        const head = try wlr.OutputConfigurationV1.Head.create(config, output.wlr_output);
        head.state.x = box.x;
        head.state.y = box.y;
    }

    root.output_manager.setConfiguration(config);
}

fn handleManagerApply(
    listener: *wl.Listener(*wlr.OutputConfigurationV1),
    config: *wlr.OutputConfigurationV1,
) void {
    const root = @fieldParentPtr(Root, "manager_apply", listener);
    defer config.destroy();

    std.log.scoped(.output_manager).info("applying output configuration", .{});

    root.processOutputConfig(config, .apply);

    root.handleOutputConfigChange() catch std.log.err("out of memory", .{});
}

fn handleManagerTest(
    listener: *wl.Listener(*wlr.OutputConfigurationV1),
    config: *wlr.OutputConfigurationV1,
) void {
    const root = @fieldParentPtr(Root, "manager_test", listener);
    defer config.destroy();

    root.processOutputConfig(config, .test_only);
}

fn processOutputConfig(
    root: *Root,
    config: *wlr.OutputConfigurationV1,
    action: enum { test_only, apply },
) void {
    // Ignore layout change events this function generates while applying the config
    root.layout_change.link.remove();
    defer root.output_layout.events.change.add(&root.layout_change);

    var success = true;

    var it = config.heads.iterator(.forward);
    while (it.next()) |head| {
        const wlr_output = head.state.output;
        const output: *Output = @ptrFromInt(wlr_output.data);

        var proposed_state = wlr.Output.State.init();
        head.state.apply(&proposed_state);

        switch (action) {
            .test_only => {
                if (!wlr_output.testState(&proposed_state)) success = false;
            },
            .apply => {
                output.applyState(&proposed_state) catch {
                    std.log.scoped(.output_manager).err("failed to apply config to output {s}", .{
                        output.wlr_output.name,
                    });
                    success = false;
                };
                if (output.wlr_output.enabled) {
                    // applyState() will always add the output to the layout on success, which means
                    // that this function cannot fail as it does not need to allocate a new layout output.
                    _ = root.output_layout.add(output.wlr_output, head.state.x, head.state.y) catch unreachable;
                }
            },
        }
    }

    if (action == .apply) root.applyPending();

    if (success) {
        config.sendSucceeded();
    } else {
        config.sendFailed();
    }
}

fn handlePowerManagerSetMode(
    _: *wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode),
    event: *wlr.OutputPowerManagerV1.event.SetMode,
) void {
    const enable = event.mode == .on;

    const log_text = if (enable) "Enabling" else "Disabling";
    std.log.scoped(.output_manager).debug(
        "{s} dpms for output {s}",
        .{ log_text, event.output.name },
    );

    event.output.enable(enable);
    event.output.commit() catch {
        std.log.scoped(.server).err("output commit failed for {s}", .{event.output.name});
    };
}

fn handleSetGamma(
    _: *wl.Listener(*wlr.GammaControlManagerV1.event.SetGamma),
    event: *wlr.GammaControlManagerV1.event.SetGamma,
) void {
    // The output may have been destroyed, in which case there is nothing to do
    const output = @as(?*Output, @ptrFromInt(event.output.data)) orelse return;

    std.log.debug("client requested to set gamma", .{});

    output.gamma_dirty = true;
    output.wlr_output.scheduleFrame();
}
