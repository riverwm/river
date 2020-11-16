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

const std = @import("std");
const build_options = @import("build_options");

const c = @import("c.zig");
const log = @import("log.zig");
const util = @import("util.zig");

const Output = @import("Output.zig");
const Server = @import("Server.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XwaylandUnmanaged = @import("XwaylandUnmanaged.zig");
const DragIcon = @import("DragIcon.zig");

/// Responsible for all windowing operations
server: *Server,

wlr_output_layout: *c.wlr_output_layout,

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
    void = if (build_options.xwayland) .{},

/// Number of pending configures sent in the current transaction.
/// A value of 0 means there is no current transaction.
pending_configures: u32 = 0,

/// Handles timeout of transactions
transaction_timer: *c.wl_event_source,

pub fn init(self: *Self, server: *Server) !void {
    // Create an output layout, which a wlroots utility for working with an
    // arrangement of screens in a physical layout.
    errdefer c.wlr_output_layout_destroy(self.wlr_output_layout);
    self.* = .{
        .server = server,
        .wlr_output_layout = c.wlr_output_layout_create() orelse return error.OutOfMemory,
        .transaction_timer = c.wl_event_loop_add_timer(
            c.wl_display_get_event_loop(self.server.wl_display),
            handleTimeout,
            self,
        ) orelse return error.AddTimerError,
        .noop_output = undefined,
    };

    const noop_wlr_output = c.wlr_noop_add_output(server.noop_backend) orelse return error.OutOfMemory;
    try self.noop_output.init(self, noop_wlr_output);
}

pub fn deinit(self: *Self) void {
    // Need to remove these listeners as the noop output will be destroyed with
    // the noop backend triggering the destroy event. However,
    // Output.handleDestroy is not intended to handle the noop output being
    // destroyed.
    c.wl_list_remove(&self.noop_output.listen_destroy.link);
    c.wl_list_remove(&self.noop_output.listen_frame.link);
    c.wl_list_remove(&self.noop_output.listen_mode.link);

    c.wlr_output_layout_destroy(self.wlr_output_layout);

    // This literally cannot fail, but for some reason returns 0
    if (c.wl_event_source_remove(self.transaction_timer) < 0) unreachable;
}

/// Removes the output in node.data from self.outputs
/// The node is not freed
pub fn removeOutput(self: *Self, node: *std.TailQueue(Output).Node) void {
    const output = &node.data;
    self.outputs.remove(node);
    output.active = false;

    // Use the first output in the list as fallback.
    // If there is no other real output, use the noop output.
    const fallback_output = if (self.outputs.first) |output_node| &output_node.data else &self.noop_output;

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
            c.wlr_layer_surface_v1_close(layer_surface.wlr_layer_surface);
        }
    }

    // If any seat has the removed output focused, focus the fallback one
    var seat_it = self.server.input_manager.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        const seat = &seat_node.data;
        if (seat.focused_output == output) {
            seat.focusOutput(fallback_output);
            seat.focus(null);
        }
    }

    // Arrange the root in case evacuated views affect the layout
    fallback_output.arrangeViews();
    self.startTransaction();
}

/// Adds the output in node.data to self.outputs
/// The Output in node.data must be initalized
pub fn addOutput(self: *Self, node: *std.TailQueue(Output).Node) void {
    self.outputs.append(node);
    node.data.active = true;

    // Add the new output to the layout. The add_auto function arranges outputs
    // from left-to-right in the order they appear. A more sophisticated
    // compositor would let the user configure the arrangement of outputs in the
    // layout. This automatically creates an output global on the wl_display.
    c.wlr_output_layout_add_auto(self.wlr_output_layout, node.data.wlr_output);

    // if we previously had no real outputs, move focus from the noop output
    // to the new one.
    if (self.outputs.len == 1) {
        // TODO: move views from the noop output to the new one and focus(null)
        var it = self.server.input_manager.seats.first;
        while (it) |seat_node| : (it = seat_node.next) {
            seat_node.data.focusOutput(&self.outputs.first.?.data);
        }
    }
}

/// Arrange all views on all outputs
pub fn arrangeAll(self: *Self) void {
    var it = self.outputs.first;
    while (it) |node| : (it = node.next) node.data.arrangeViews();
}

/// Initiate an atomic change to the layout. This change will not be
/// applied until all affected clients ack a configure and commit a buffer.
pub fn startTransaction(self: *Self) void {
    // If a new transaction is started while another is in progress, we need
    // to reset the pending count to 0 and clear serials from the views
    self.pending_configures = 0;

    // Iterate over all views of all outputs
    var output_it = self.outputs.first;
    while (output_it) |output_node| : (output_it = output_node.next) {
        var view_it = output_node.data.views.first;
        while (view_it) |view_node| : (view_it = view_node.next) {
            const view = &view_node.view;

            if (view.destroying) {
                if (view.saved_buffers.items.len == 0) view.saveBuffers();
                continue;
            }

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
        log.debug(
            .transaction,
            "started transaction with {} pending configure(s)",
            .{self.pending_configures},
        );

        // Set timeout to 200ms
        if (c.wl_event_source_timer_update(self.transaction_timer, 200) < 0) {
            log.err(.transaction, "failed to update timer", .{});
            self.commitTransaction();
        }
    } else {
        // No views need configures, clear the current timer in case we are
        // interrupting another transaction and commit.
        if (c.wl_event_source_timer_update(self.transaction_timer, 0) < 0)
            log.err(.transaction, "error disarming timer", .{});
        self.commitTransaction();
    }
}

fn handleTimeout(data: ?*c_void) callconv(.C) c_int {
    const self = util.voidCast(Self, data.?);

    log.err(.transaction, "timeout occurred, some imperfect frames may be shown", .{});

    self.pending_configures = 0;

    self.commitTransaction();

    return 0;
}

pub fn notifyConfigured(self: *Self) void {
    self.pending_configures -= 1;
    if (self.pending_configures == 0) {
        // Disarm the timer, as we didn't timeout
        if (c.wl_event_source_timer_update(self.transaction_timer, 0) == -1)
            log.err(.transaction, "error disarming timer", .{});
        self.commitTransaction();
    }
}

/// Apply the pending state and drop stashed buffers. This means that
/// the next frame drawn will be the post-transaction state of the
/// layout. Should only be called after all clients have configured for
/// the new layout. If called early imperfect frames may be drawn.
fn commitTransaction(self: *Self) void {
    std.debug.assert(self.pending_configures == 0);

    // Iterate over all views of all outputs
    var output_it = self.outputs.first;
    while (output_it) |output_node| : (output_it = output_node.next) {
        const output = &output_node.data;

        // Apply pending state of the output
        const output_tags_changed = output.pending.tags != output.current.tags;
        output.current = output.pending;
        if (output_tags_changed) {
            log.debug(
                .output,
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

            if (view.destroying) {
                view_it = view_node.next;
                view.destroy();
                continue;
            }
            defer view_it = view_node.next;

            if (!view.shouldTrackConfigure() and view.pending_serial != null) continue;

            // Apply pending state of the view
            view.pending_serial = null;
            if (view.pending.tags != view.current.tags) view_tags_changed = true;
            view.current = view.pending;

            view.dropSavedBuffers();

            view.commitOpacityTransition();
        }

        if (view_tags_changed) output.sendViewTags();
    }
}
