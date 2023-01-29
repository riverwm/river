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

const Self = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const DragIcon = @import("DragIcon.zig");
const LayerSurface = @import("LayerSurface.zig");
const LockSurface = @import("LockSurface.zig");
const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");

scene: *wlr.Scene,

new_output: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleNewOutput),

output_layout: *wlr.OutputLayout,
layout_change: wl.Listener(*wlr.OutputLayout) = wl.Listener(*wlr.OutputLayout).init(handleLayoutChange),

output_manager: *wlr.OutputManagerV1,
manager_apply: wl.Listener(*wlr.OutputConfigurationV1) =
    wl.Listener(*wlr.OutputConfigurationV1).init(handleManagerApply),
manager_test: wl.Listener(*wlr.OutputConfigurationV1) =
    wl.Listener(*wlr.OutputConfigurationV1).init(handleManagerTest),

power_manager: *wlr.OutputPowerManagerV1,
power_manager_set_mode: wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode) =
    wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode).init(handlePowerManagerSetMode),

/// A list of all outputs
all_outputs: std.TailQueue(*Output) = .{},

/// A list of all active outputs. See Output.active
outputs: std.TailQueue(Output) = .{},

/// This output is used internally when no real outputs are available.
/// It is not advertised to clients.
noop_output: Output = undefined,

/// This list stores all "override redirect" Xwayland windows. This needs to be in root
/// since X is like the wild west and who knows where these things will place themselves.
xwayland_override_redirect_views: if (build_options.xwayland)
    std.TailQueue(XwaylandOverrideRedirect)
else
    void = if (build_options.xwayland)
.{},

/// Number of layout demands pending before the transaction may be started.
pending_layout_demands: u32 = 0,
/// Number of pending configures sent in the current transaction.
/// A value of 0 means there is no current transaction.
pending_configures: u32 = 0,
/// Handles timeout of transactions
transaction_timer: *wl.EventSource,

pub fn init(self: *Self) !void {
    const output_layout = try wlr.OutputLayout.create();
    errdefer output_layout.destroy();

    const scene = try wlr.Scene.create();
    errdefer scene.tree.node.destroy();

    try scene.attachOutputLayout(output_layout);

    _ = try wlr.XdgOutputManagerV1.create(server.wl_server, output_layout);

    const event_loop = server.wl_server.getEventLoop();
    const transaction_timer = try event_loop.addTimer(*Self, handleTransactionTimeout, self);
    errdefer transaction_timer.remove();

    const noop_wlr_output = try server.headless_backend.headlessAddOutput(1920, 1080);
    self.* = .{
        .scene = scene,
        .output_layout = output_layout,
        .output_manager = try wlr.OutputManagerV1.create(server.wl_server),
        .power_manager = try wlr.OutputPowerManagerV1.create(server.wl_server),
        .transaction_timer = transaction_timer,
        .noop_output = .{
            .wlr_output = noop_wlr_output,
            .tree = try scene.tree.createSceneTree(),
            .usable_box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        },
    };
    noop_wlr_output.data = @ptrToInt(&self.noop_output);

    server.backend.events.new_output.add(&self.new_output);
    self.output_manager.events.apply.add(&self.manager_apply);
    self.output_manager.events.@"test".add(&self.manager_test);
    self.output_layout.events.change.add(&self.layout_change);
    self.power_manager.events.set_mode.add(&self.power_manager_set_mode);
}

pub fn deinit(self: *Self) void {
    self.scene.tree.node.destroy();
    self.output_layout.destroy();
    self.transaction_timer.remove();
}

pub const AtResult = struct {
    surface: ?*wlr.Surface,
    sx: f64,
    sy: f64,
    node: union(enum) {
        view: *View,
        layer_surface: *LayerSurface,
        lock_surface: *LockSurface,
        xwayland_override_redirect: if (build_options.xwayland) *XwaylandOverrideRedirect else noreturn,
    },
};

/// Return information about what is currently rendered at the given layout coordinates.
pub fn at(self: Self, lx: f64, ly: f64) ?AtResult {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    const node_at = self.scene.tree.node.at(lx, ly, &sx, &sy) orelse return null;

    const surface: ?*wlr.Surface = blk: {
        if (node_at.type == .buffer) {
            const scene_buffer = wlr.SceneBuffer.fromNode(node_at);
            if (wlr.SceneSurface.fromBuffer(scene_buffer)) |scene_surface| {
                break :blk scene_surface.surface;
            }
        }
        break :blk null;
    };

    {
        var it: ?*wlr.SceneNode = node_at;
        while (it) |node| : (it = node.parent) {
            if (@intToPtr(?*SceneNodeData, node.data)) |scene_node_data| {
                switch (scene_node_data.data) {
                    .view => |view| return .{
                        .surface = surface,
                        .sx = sx,
                        .sy = sy,
                        .node = .{ .view = view },
                    },
                }
            }
        }
    }

    return null;
}

fn handleNewOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const self = @fieldParentPtr(Self, "new_output", listener);
    std.log.scoped(.output_manager).debug("new output {s}", .{wlr_output.name});

    const node = util.gpa.create(std.TailQueue(Output).Node) catch {
        wlr_output.destroy();
        return;
    };
    node.data.init(wlr_output) catch {
        wlr_output.destroy();
        util.gpa.destroy(node);
        return;
    };
    const ptr_node = util.gpa.create(std.TailQueue(*Output).Node) catch {
        wlr_output.destroy();
        util.gpa.destroy(node);
        return;
    };
    ptr_node.data = &node.data;

    self.all_outputs.append(ptr_node);
    self.addOutput(&node.data);
}

/// Remove the output from self.outputs and evacuate views if it is a member of
/// the list. The node is not freed
pub fn removeOutput(self: *Self, output: *Output) void {
    const node = @fieldParentPtr(std.TailQueue(Output).Node, "data", output);

    // If the node has already been removed, do nothing
    var output_it = self.outputs.first;
    while (output_it) |n| : (output_it = n.next) {
        if (n == node) break;
    } else return;

    self.outputs.remove(node);

    // Use the first output in the list as fallback. If the last real output
    // is being removed, use the noop output.
    const fallback_output = blk: {
        if (self.outputs.first) |output_node| {
            break :blk &output_node.data;
        } else {
            // Store the focused output tags if we are hotplugged down to
            // 0 real outputs so they can be restored on gaining a new output.
            self.noop_output.current.tags = output.current.tags;
            break :blk &self.noop_output;
        }
    };

    // Move all views from the destroyed output to the fallback one
    while (output.views.last) |view_node| {
        const view = &view_node.view;
        view.sendToOutput(fallback_output);
    }

    // Close all layer surfaces on the removed output
    for (output.layers) |*layer| {
        // Destroying the layer surface will cause it to be removed from this list.
        while (layer.first) |layer_node| layer_node.data.wlr_layer_surface.destroy();
    }

    // If any seat has the removed output focused, focus the fallback one
    var seat_it = server.input_manager.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        const seat = &seat_node.data;
        if (seat.focused_output == output) {
            seat.focusOutput(fallback_output);
            seat.focus(null);
        }
    }

    // Destroy all layouts of the output
    while (output.layouts.first) |layout_node| layout_node.data.destroy();

    while (output.status_trackers.first) |status_node| status_node.data.destroy();

    // Arrange the root in case evacuated views affect the layout
    fallback_output.arrangeViews();
    self.startTransaction();
}

/// Add the output to self.outputs and the output layout if it has not
/// already been added.
pub fn addOutput(self: *Self, output: *Output) void {
    const node = @fieldParentPtr(std.TailQueue(Output).Node, "data", output);

    // If we have already added the output, do nothing and return
    var output_it = self.outputs.first;
    while (output_it) |n| : (output_it = n.next) if (n == node) return;

    self.outputs.append(node);

    // This aarranges outputs from left-to-right in the order they appear. The
    // wlr-output-management protocol may be used to modify this arrangement.
    // This also creates a wl_output global which is advertised to clients.
    self.output_layout.addAuto(output.wlr_output);

    const layout_output = self.output_layout.get(output.wlr_output).?;
    output.tree.node.setEnabled(true);
    output.tree.node.setPosition(layout_output.x, layout_output.y);

    // If we previously had no real outputs, move focus from the noop output
    // to the new one.
    if (self.outputs.len == 1) {
        // Restore the focused tags of the last output to be removed
        output.pending.tags = self.noop_output.current.tags;
        output.current.tags = self.noop_output.current.tags;

        // Move all views from noop output to the new output
        while (self.noop_output.views.last) |n| n.view.sendToOutput(output);

        // Focus the new output with all seats
        var it = server.input_manager.seats.first;
        while (it) |seat_node| : (it = seat_node.next) {
            const seat = &seat_node.data;
            seat.focusOutput(output);
            seat.focus(null);
        }
    }
}

/// Arrange all views on all outputs
pub fn arrangeAll(self: *Self) void {
    var it = self.outputs.first;
    while (it) |node| : (it = node.next) node.data.arrangeViews();
}

/// Record the number of currently pending layout demands so that a transaction
/// can be started once all are either complete or have timed out.
pub fn trackLayoutDemands(self: *Self) void {
    self.pending_layout_demands = 0;

    var it = self.outputs.first;
    while (it) |node| : (it = node.next) {
        if (node.data.layout_demand != null) self.pending_layout_demands += 1;
    }
    assert(self.pending_layout_demands > 0);
}

/// This function is used to inform the transaction system that a layout demand
/// has either been completed or timed out. If it was the last pending layout
/// demand in the current sequence, a transaction is started.
pub fn notifyLayoutDemandDone(self: *Self) void {
    self.pending_layout_demands -= 1;
    if (self.pending_layout_demands == 0) self.startTransaction();
}

/// Initiate an atomic change to the layout. This change will not be
/// applied until all affected clients ack a configure and commit a buffer.
pub fn startTransaction(self: *Self) void {
    // If one or more layout demands are currently in progress, postpone
    // transactions until they complete. Every frame must be perfect.
    if (self.pending_layout_demands > 0) return;

    // If a new transaction is started while another is in progress, we need
    // to reset the pending count to 0 and clear serials from the views
    const preempting = self.pending_configures > 0;
    self.pending_configures = 0;

    // Iterate over all views of all outputs
    var output_it = self.outputs.first;
    while (output_it) |output_node| : (output_it = output_node.next) {
        var view_it = output_node.data.views.first;
        while (view_it) |view_node| : (view_it = view_node.next) {
            const view = &view_node.view;

            if (!view.tree.node.enabled) continue;

            if (view.shouldTrackConfigure()) {
                // Clear the serial in case this transaction is interrupting a prior one.
                view.pending_serial = null;

                if (view.needsConfigure()) {
                    view.configure();
                    self.pending_configures += 1;

                    // Send a frame done that the client will commit a new frame
                    // with the dimensions we sent in the configure. Normally this
                    // event would be sent in the render function.
                    view.sendFrameDone();
                }

                // If there are saved buffers present, then this transaction is interrupting
                // a previous transaction and we should keep the old buffers.
                if (view.saved_buffers.items.len == 0) view.saveBuffers();
            } else {
                if (view.needsConfigure()) view.configure();
            }
        }
    }

    if (self.pending_configures > 0) {
        std.log.scoped(.transaction).debug("started transaction with {} pending configure(s)", .{
            self.pending_configures,
        });

        // Timeout the transaction after 200ms. If we are preempting an
        // already in progress transaction, don't extend the timeout.
        if (!preempting) {
            self.transaction_timer.timerUpdate(200) catch {
                std.log.scoped(.transaction).err("failed to update timer", .{});
                self.commitTransaction();
            };
        }
    } else {
        // No views need configures, clear the current timer in case we are
        // interrupting another transaction and commit.
        self.transaction_timer.timerUpdate(0) catch std.log.scoped(.transaction).err("error disarming timer", .{});
        self.commitTransaction();
    }
}

fn handleTransactionTimeout(self: *Self) c_int {
    std.log.scoped(.transaction).err("timeout occurred, some imperfect frames may be shown", .{});

    self.pending_configures = 0;
    self.commitTransaction();

    return 0;
}

pub fn notifyConfigured(self: *Self) void {
    self.pending_configures -= 1;
    if (self.pending_configures == 0) {
        // Disarm the timer, as we didn't timeout
        self.transaction_timer.timerUpdate(0) catch std.log.scoped(.transaction).err("error disarming timer", .{});
        self.commitTransaction();
    }
}

/// Apply the pending state and drop stashed buffers. This means that
/// the next frame drawn will be the post-transaction state of the
/// layout. Should only be called after all clients have configured for
/// the new layout. If called early imperfect frames may be drawn.
fn commitTransaction(self: *Self) void {
    assert(self.pending_configures == 0);

    // Iterate over all views of all outputs
    var output_it = self.outputs.first;
    while (output_it) |output_node| : (output_it = output_node.next) {
        const output = &output_node.data;

        // Apply pending state of the output
        if (output.pending.tags != output.current.tags) {
            std.log.scoped(.output).debug(
                "changing current focus: {b:0>10} to {b:0>10}",
                .{ output.current.tags, output.pending.tags },
            );
            var it = output.status_trackers.first;
            while (it) |node| : (it = node.next) node.data.sendFocusedTags(output.pending.tags);
        }
        output.current = output.pending;

        var view_tags_changed = false;
        var urgent_tags_dirty = false;

        var view_it = output.views.first;
        while (view_it) |view_node| {
            const view = &view_node.view;
            view_it = view_node.next;

            if (!view.tree.node.enabled) {
                view.dropSavedBuffers();
                view.output.views.remove(view_node);
                if (view.destroying) view.destroy();
                continue;
            }
            assert(!view.destroying);

            if (view.pending_serial != null and !view.shouldTrackConfigure()) continue;

            // Apply pending state of the view
            view.pending_serial = null;
            if (view.pending.tags != view.current.tags) view_tags_changed = true;
            if (view.pending.urgent != view.current.urgent) urgent_tags_dirty = true;
            if (view.pending.urgent and view_tags_changed) urgent_tags_dirty = true;
            view.current = view.pending;

            view.tree.node.setPosition(view.current.box.x, view.current.box.y);

            view.dropSavedBuffers();
        }

        if (view_tags_changed) output.sendViewTags();
        if (urgent_tags_dirty) output.sendUrgentTags();
    }
    server.input_manager.updateCursorState();
    server.idle_inhibitor_manager.idleInhibitCheckActive();
}

/// Send the new output configuration to all wlr-output-manager clients
fn handleLayoutChange(listener: *wl.Listener(*wlr.OutputLayout), _: *wlr.OutputLayout) void {
    const self = @fieldParentPtr(Self, "layout_change", listener);

    const config = self.currentOutputConfig() catch {
        std.log.scoped(.output_manager).err("out of memory", .{});
        return;
    };
    self.output_manager.setConfiguration(config);
}

fn handleManagerApply(
    listener: *wl.Listener(*wlr.OutputConfigurationV1),
    config: *wlr.OutputConfigurationV1,
) void {
    const self = @fieldParentPtr(Self, "manager_apply", listener);
    defer config.destroy();

    self.processOutputConfig(config, .apply);

    // Send the config that was actually applied
    const applied_config = self.currentOutputConfig() catch {
        std.log.scoped(.output_manager).err("out of memory", .{});
        return;
    };
    self.output_manager.setConfiguration(applied_config);
}

fn handleManagerTest(
    listener: *wl.Listener(*wlr.OutputConfigurationV1),
    config: *wlr.OutputConfigurationV1,
) void {
    const self = @fieldParentPtr(Self, "manager_test", listener);
    defer config.destroy();

    self.processOutputConfig(config, .test_only);
}

fn processOutputConfig(
    self: *Self,
    config: *wlr.OutputConfigurationV1,
    action: enum { test_only, apply },
) void {
    // Ignore layout change events this function generates while applying the config
    self.layout_change.link.remove();
    defer self.output_layout.events.change.add(&self.layout_change);

    var success = true;

    var it = config.heads.iterator(.forward);
    while (it.next()) |head| {
        const wlr_output = head.state.output;
        const output = @intToPtr(*Output, wlr_output.data);

        var proposed_state = wlr.Output.State.init();
        head.state.apply(&proposed_state);

        switch (action) {
            .test_only => {
                if (!wlr_output.testState(&proposed_state)) success = false;
            },
            .apply => {
                if (wlr_output.commitState(&proposed_state)) {
                    if (head.state.enabled) {
                        // Just updates the output's position if it is already in the layout
                        self.output_layout.add(output.wlr_output, head.state.x, head.state.y);
                        output.tree.node.setEnabled(true);
                        output.tree.node.setPosition(head.state.x, head.state.y);
                        output.arrangeLayers(.mapped);
                    } else {
                        self.removeOutput(output);
                        self.output_layout.remove(output.wlr_output);
                        output.tree.node.setEnabled(false);
                    }
                } else {
                    std.log.scoped(.output_manager).err("failed to apply config to output {s}", .{
                        output.wlr_output.name,
                    });
                    success = false;
                }
            },
        }
    }

    if (action == .apply) self.startTransaction();

    if (success) {
        config.sendSucceeded();
    } else {
        config.sendFailed();
    }
}

fn currentOutputConfig(self: *Self) !*wlr.OutputConfigurationV1 {
    // TODO there no real reason this needs to allocate memory every time it is called.
    // consider improving this wlroots api or reimplementing in zig-wlroots/river.
    const config = try wlr.OutputConfigurationV1.create();
    // this destroys all associated config heads as well
    errdefer config.destroy();

    var it = self.all_outputs.first;
    while (it) |node| : (it = node.next) {
        const output = node.data;
        const head = try wlr.OutputConfigurationV1.Head.create(config, output.wlr_output);

        // If the output is not part of the layout (and thus disabled)
        // the box will be zeroed out.
        var box: wlr.Box = undefined;
        self.output_layout.getBox(output.wlr_output, &box);
        head.state.x = box.x;
        head.state.y = box.y;
    }

    return config;
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
