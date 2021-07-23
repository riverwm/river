// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
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
const mem = std.mem;
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XwaylandUnmanaged = @import("XwaylandUnmanaged.zig");
const DragIcon = @import("DragIcon.zig");

// Minimum effective width/height for outputs.
// This is needed, to prevent integer overflows caused by the output effective
// resolution beeing too small to fit clients that can't get scaled more and
// thus will be bigger than the output resolution.
// The value is totally arbitrary and low enough, that it should never be
// encountered during normal usage.
const min_size = 50;

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

drag_icons: std.SinglyLinkedList(DragIcon) = .{},

/// This list stores all unmanaged Xwayland windows. This needs to be in root
/// since X is like the wild west and who knows where these things will go.
xwayland_unmanaged_views: if (build_options.xwayland)
    std.TailQueue(XwaylandUnmanaged)
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

    _ = try wlr.XdgOutputManagerV1.create(server.wl_server, output_layout);

    const event_loop = server.wl_server.getEventLoop();
    const transaction_timer = try event_loop.addTimer(*Self, handleTransactionTimeout, self);
    errdefer transaction_timer.remove();

    const noop_wlr_output = try server.noop_backend.noopAddOutput();
    self.* = .{
        .output_layout = output_layout,
        .output_manager = try wlr.OutputManagerV1.create(server.wl_server),
        .power_manager = try wlr.OutputPowerManagerV1.create(server.wl_server),
        .transaction_timer = transaction_timer,
        .noop_output = .{
            .wlr_output = noop_wlr_output,
            // TODO: find a good way to not create a wlr.OutputDamage for the noop output
            .damage = try wlr.OutputDamage.create(noop_wlr_output),
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
    self.output_layout.destroy();
    self.transaction_timer.remove();
}

fn handleNewOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const self = @fieldParentPtr(Self, "new_output", listener);
    std.log.scoped(.output_manager).debug("new output {s}", .{mem.sliceTo(&wlr_output.name, 0)});

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
    for (output.layers) |*layer, layer_idx| {
        while (layer.pop()) |layer_node| {
            const layer_surface = &layer_node.data;
            // We need to move the closing layer surface to the noop output
            // since it may not be immediately destoryed. This just a request
            // to close which will trigger unmap and destroy events in
            // response, and the LayerSurface needs a valid output to
            // handle them.
            self.noop_output.layers[layer_idx].prepend(layer_node);
            layer_surface.output = &self.noop_output;
            layer_surface.wlr_layer_surface.close();
        }
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
    self.output_layout.addAuto(node.data.wlr_output);

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

            if (view.destroying) continue;

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

fn handleTransactionTimeout(self: *Self) callconv(.C) c_int {
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
        const output_tags_changed = output.pending.tags != output.current.tags;
        output.current = output.pending;
        if (output_tags_changed) {
            std.log.scoped(.output).debug(
                "changing current focus: {b:0>10} to {b:0>10}",
                .{ output.current.tags, output.pending.tags },
            );
            var it = output.status_trackers.first;
            while (it) |node| : (it = node.next) node.data.sendFocusedTags();
        }

        var view_tags_changed = false;

        var view_it = output.views.first;
        while (view_it) |view_node| {
            const view = &view_node.view;
            view_it = view_node.next;

            if (view.destroying) {
                view.destroy();
                continue;
            }

            if (view.pending_serial != null and !view.shouldTrackConfigure()) continue;

            // Apply pending state of the view
            view.pending_serial = null;
            if (view.pending.tags != view.current.tags) view_tags_changed = true;
            view.current = view.pending;

            view.dropSavedBuffers();
        }

        if (view_tags_changed) output.sendViewTags();

        output.damage.addWhole();
    }
    server.input_manager.updateCursorState();
}

/// Send the new output configuration to all wlr-output-manager clients
fn handleLayoutChange(
    listener: *wl.Listener(*wlr.OutputLayout),
    output_layout: *wlr.OutputLayout,
) void {
    const self = @fieldParentPtr(Self, "layout_change", listener);

    const config = self.outputConfigFromCurrent() catch {
        std.log.scoped(.output_manager).crit("out of memory", .{});
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

    if (self.applyOutputConfig(config)) {
        config.sendSucceeded();
    } else {
        config.sendFailed();
    }

    // Send the config that was actually applied
    const applied_config = self.outputConfigFromCurrent() catch {
        std.log.scoped(.output_manager).crit("out of memory", .{});
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

    if (testOutputConfig(config, true)) {
        config.sendSucceeded();
    } else {
        config.sendFailed();
    }
}

/// Apply the given config, return false on faliure
fn applyOutputConfig(self: *Self, config: *wlr.OutputConfigurationV1) bool {
    // Ignore layout change events while applying the config
    self.layout_change.link.remove();
    defer self.output_layout.events.change.add(&self.layout_change);

    // Test if the config should apply cleanly
    if (!testOutputConfig(config, false)) return false;

    var it = config.heads.iterator(.forward);
    while (it.next()) |head| {
        const output = @intToPtr(*Output, head.state.output.data);
        const disable = output.wlr_output.enabled and !head.state.enabled;

        // Since we have done a successful test commit, this will only fail
        // due to error in the output's backend implementation.
        output.wlr_output.commit() catch
            std.log.scoped(.output_manager).err("output commit failed for {s}", .{mem.sliceTo(&output.wlr_output.name, 0)});

        if (output.wlr_output.enabled) {
            // Moves the output if it is already in the layout
            self.output_layout.add(output.wlr_output, head.state.x, head.state.y);
        }

        if (disable) {
            self.removeOutput(output);
            self.output_layout.remove(output.wlr_output);
        }

        // Arrange layers to adjust the usable_box
        // We dont need to call arrangeViews() since arrangeLayers() will call
        // it for us because the usable_box changed
        output.arrangeLayers(.mapped);
        self.startTransaction();
    }

    return true;
}

/// Tests the output configuration.
/// If rollback is false all changes are applied to the pending state of the affected outputs.
fn testOutputConfig(config: *wlr.OutputConfigurationV1, rollback: bool) bool {
    var ok = true;
    var it = config.heads.iterator(.forward);
    while (it.next()) |head| {
        const wlr_output = head.state.output;

        const width = if (head.state.mode) |m| m.width else head.state.custom_mode.width;
        const height = if (head.state.mode) |m| m.height else head.state.custom_mode.height;
        const scale = head.state.scale;

        const too_small = (@intToFloat(f32, width) / scale < min_size) or
            (@intToFloat(f32, height) / scale < min_size);

        if (too_small) {
            std.log.scoped(.output_manager).info(
                "The requested output resolution {}x{} scaled with {} for {s} would be too small.",
                .{ width, height, scale, mem.sliceTo(&wlr_output.name, 0) },
            );
        }

        applyHeadToOutput(head, wlr_output);
        ok = ok and !too_small and wlr_output.testCommit();
    }

    if (rollback or !ok) {
        // Rollback all changes
        it = config.heads.iterator(.forward);
        while (it.next()) |head| head.state.output.rollback();
    }

    return ok;
}

fn applyHeadToOutput(head: *wlr.OutputConfigurationV1.Head, wlr_output: *wlr.Output) void {
    wlr_output.enable(head.state.enabled);
    // The output must be enabled for the following properties to apply
    if (head.state.enabled) {
        // TODO(wlroots) Somehow on the drm backend setting the mode causes
        // the commit in the rendering loop to fail. The commit that
        // applies the mode works fine.
        // We can just ignore this because nothing bad happens but it
        // should be fixed in the future
        // See https://github.com/swaywm/wlroots/issues/2492
        if (head.state.mode) |mode| {
            wlr_output.setMode(mode);
        } else {
            const custom_mode = &head.state.custom_mode;
            wlr_output.setCustomMode(custom_mode.width, custom_mode.height, custom_mode.refresh);
        }
        wlr_output.setScale(head.state.scale);
        wlr_output.setTransform(head.state.transform);
    }
}

/// Create the config describing the current configuration
fn outputConfigFromCurrent(self: *Self) !*wlr.OutputConfigurationV1 {
    const config = try wlr.OutputConfigurationV1.create();
    // this destroys all associated config heads as well
    errdefer config.destroy();

    var it = self.all_outputs.first;
    while (it) |node| : (it = node.next) try self.createHead(node.data, config);

    return config;
}

fn createHead(self: *Self, output: *Output, config: *wlr.OutputConfigurationV1) !void {
    const head = try wlr.OutputConfigurationV1.Head.create(config, output.wlr_output);

    // If the output is not part of the layout (and thus disabled) we dont care
    // about the position
    if (self.output_layout.getBox(output.wlr_output)) |box| {
        head.state.x = box.x;
        head.state.y = box.y;
    }
}

fn handlePowerManagerSetMode(
    listener: *wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode),
    event: *wlr.OutputPowerManagerV1.event.SetMode,
) void {
    const self = @fieldParentPtr(Self, "power_manager_set_mode", listener);

    const enable = event.mode == .on;

    const log_text = if (enable) "Enabling" else "Disabling";
    std.log.scoped(.output_manager).debug(
        "{s} dpms for output {s}",
        .{ log_text, mem.sliceTo(&event.output.name, 0) },
    );

    event.output.enable(enable);
    event.output.commit() catch {
        std.log.scoped(.server).err("output commit failed for {s}", .{mem.sliceTo(&event.output.name, 0)});
    };
}
