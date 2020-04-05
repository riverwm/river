const std = @import("std");
const c = @import("c.zig");
const util = @import("util.zig");

const Log = @import("log.zig").Log;
const Output = @import("output.zig").Output;
const Server = @import("server.zig").Server;
const Seat = @import("seat.zig").Seat;
const View = @import("view.zig").View;
const ViewStack = @import("view_stack.zig").ViewStack;

/// Responsible for all windowing operations
pub const Root = struct {
    const Self = @This();

    server: *Server,

    wlr_output_layout: *c.wlr_output_layout,
    outputs: std.TailQueue(Output),

    /// The top of the stack is the "most important" view.
    views: ViewStack,

    /// The view that has seat focus, if any.
    focused_view: ?*View,

    /// A bit field of focused tags
    current_focused_tags: u32,
    pending_focused_tags: ?u32,

    /// Number of views in "master" section of the screen.
    master_count: u32,

    /// Percentage of the total screen that the master section takes up.
    master_factor: f64,

    /// Width of borders in pixels
    border_width: u32,

    /// Width of inner gaps in pixels
    inner_gap_width: u32,

    /// Number of pending configures sent in the current transaction.
    /// A value of 0 means there is no current transaction.
    pending_configures: u32,

    /// Handles timeout of transactions
    transaction_timer: ?*c.wl_event_source,

    pub fn init(self: *Self, server: *Server) !void {
        self.server = server;

        // Create an output layout, which a wlroots utility for working with an
        // arrangement of screens in a physical layout.
        self.wlr_output_layout = c.wlr_output_layout_create() orelse
            return error.CantCreateWlrOutputLayout;
        errdefer c.wlr_output_layout_destroy(self.wlr_output_layout);

        self.outputs = std.TailQueue(Output).init();

        self.views.init();

        self.focused_view = null;

        self.current_focused_tags = 1 << 0;
        self.pending_focused_tags = null;

        self.master_count = 1;

        self.master_factor = 0.6;

        self.border_width = 4;

        self.inner_gap_width = 10;

        self.pending_configures = 0;

        self.transaction_timer = null;
    }

    pub fn destroy(self: Self) void {
        c.wlr_output_layout_destroy(self.wlr_output_layout);
    }

    pub fn addOutput(self: *Self, wlr_output: *c.wlr_output) void {
        // TODO: Handle failure
        const node = self.outputs.allocateNode(self.server.allocator) catch unreachable;
        node.data.init(self, wlr_output) catch unreachable;
        self.outputs.append(node);
    }

    pub fn addView(self: *Self, wlr_xdg_surface: *c.wlr_xdg_surface) void {
        const node = self.server.allocator.create(ViewStack.Node) catch unreachable;
        node.view.init(self, wlr_xdg_surface, self.current_focused_tags);
        self.views.push(node);
    }

    /// Finds the topmost view under the output layout coordinates lx, ly
    /// returns the view if found, and a pointer to the wlr_surface as well as the surface coordinates
    pub fn viewAt(self: Self, lx: f64, ly: f64, surface: *?*c.wlr_surface, sx: *f64, sy: *f64) ?*View {
        var it = ViewStack.iterator(self.views.first, 0xFFFFFFFF);
        while (it.next()) |view| {
            if (view.isAt(lx, ly, surface, sx, sy)) {
                return view;
            }
        }
        return null;
    }

    /// Clear the current focus.
    pub fn clearFocus(self: *Self) void {
        if (self.focused_view) |view| {
            _ = c.wlr_xdg_toplevel_set_activated(view.wlr_xdg_surface, false);
        }
        self.focused_view = null;
    }

    /// Focus the next visible view in the stack, wrapping if needed. Does
    /// nothing if there is only one view in the stack.
    pub fn focusNextView(self: *Self) void {
        if (self.focused_view) |current_focus| {
            // If there is a currently focused view, focus the next visible view in the stack.
            const current_node = @fieldParentPtr(ViewStack.Node, "view", current_focus);
            var it = ViewStack.iterator(current_node, self.current_focused_tags);
            // Skip past the current node
            _ = it.next();
            // Focus the next visible node if there is one
            if (it.next()) |view| {
                view.focus(view.wlr_xdg_surface.surface);
                return;
            }
        }

        // There is either no currently focused view or the last visible view in the
        // stack is focused and we need to wrap.
        var it = ViewStack.iterator(self.views.first, self.current_focused_tags);
        if (it.next()) |view| {
            view.focus(view.wlr_xdg_surface.surface);
        } else {
            // Otherwise clear the focus since there are no visible views
            self.clearFocus();
        }
    }

    /// Focus the previous view in the stack, wrapping if needed. Does nothing
    /// if there is only one view in the stack.
    pub fn focusPrevView(self: *Self) void {
        if (self.focused_view) |current_focus| {
            // If there is a currently focused view, focus the previous visible view in the stack.
            const current_node = @fieldParentPtr(ViewStack.Node, "view", current_focus);
            var it = ViewStack.reverseIterator(current_node, self.current_focused_tags);
            // Skip past the current node
            _ = it.next();
            // Focus the previous visible node if there is one
            if (it.next()) |view| {
                view.focus(view.wlr_xdg_surface.surface);
                return;
            }
        }

        // There is either no currently focused view or the first visible view in the
        // stack is focused and we need to wrap.
        var it = ViewStack.reverseIterator(self.views.last, self.current_focused_tags);
        if (it.next()) |view| {
            view.focus(view.wlr_xdg_surface.surface);
        } else {
            // Otherwise clear the focus since there are no visible views
            self.clearFocus();
        }
    }

    pub fn arrange(self: *Self) void {
        const root_tags = if (self.pending_focused_tags) |tags|
            tags
        else
            self.current_focused_tags;

        const visible_count = blk: {
            var count: u32 = 0;
            var it = ViewStack.pendingIterator(self.views.first, root_tags);
            while (it.next() != null) count += 1;
            break :blk count;
        };

        const master_count = util.min(u32, self.master_count, visible_count);
        const slave_count = if (master_count >= visible_count) 0 else visible_count - master_count;

        // This can't return null if we pass null as the reference
        const output_box: *c.wlr_box = c.wlr_output_layout_get_box(self.wlr_output_layout, null);
        var master_column_width: u32 = undefined;
        var slave_column_width: u32 = undefined;
        if (master_count > 0 and slave_count > 0) {
            // If both master and slave views are present
            master_column_width = @floatToInt(u32, @round(@intToFloat(f64, output_box.width) * self.master_factor));
            slave_column_width = @intCast(u32, output_box.width) - master_column_width;
        } else if (master_count > 0) {
            master_column_width = @intCast(u32, output_box.width);
            slave_column_width = 0;
        } else {
            slave_column_width = @intCast(u32, output_box.width);
            master_column_width = 0;
        }

        var i: u32 = 0;
        var it = ViewStack.pendingIterator(self.views.first, root_tags);
        while (it.next()) |view| {
            if (i < master_count) {
                // Add the remainder to the first master to ensure every pixel of height is used
                const master_height = @divTrunc(@intCast(u32, output_box.height), master_count);
                const master_height_rem = @intCast(u32, output_box.height) % master_count;

                view.pending_box = View.Box{
                    .x = 0,
                    .y = @intCast(i32, i * master_height +
                        if (i > 0) master_height_rem else 0),

                    .width = master_column_width,
                    .height = master_height + if (i == 0) master_height_rem else 0,
                };
            } else {
                // Add the remainder to the first slave to ensure every pixel of height is used
                const slave_height = @divTrunc(@intCast(u32, output_box.height), slave_count);
                const slave_height_rem = @intCast(u32, output_box.height) % slave_count;

                view.pending_box = View.Box{
                    .x = @intCast(i32, master_column_width),
                    .y = @intCast(i32, (i - master_count) * slave_height +
                        if (i > master_count) slave_height_rem else 0),

                    .width = slave_column_width,
                    .height = slave_height +
                        if (i == master_count) slave_height_rem else 0,
                };
            }

            i += 1;
        }

        self.startTransaction();
    }

    /// Initiate an atomic change to the layout. This change will not be
    /// applied until all affected clients ack a configure and commit a buffer.
    fn startTransaction(self: *Self) void {
        // If a new transaction is started while another is in progress, we need
        // to reset the pending count to 0 and clear serials from the views
        self.pending_configures = 0;

        var it = ViewStack.iterator(self.views.first, 0xFFFFFFFF);
        while (it.next()) |view| {
            // Clear the serial in case this transaction is interrupting a prior one.
            view.pending_serial = null;

            if (view.needsConfigure()) {
                view.configurePending();
                self.pending_configures += 1;

                // We save the current buffer, so we can send an early
                // frame done event to give the client a head start on
                // redrawing.
                view.sendFrameDone();
            }

            // If there is a saved buffer present, then this transaction is interrupting
            // a previous transaction and we should keep the old buffer.
            if (view.stashed_buffer == null) {
                view.stashBuffer();
            }
        }

        Log.Debug.log(
            "Started transaction with {} pending configures.",
            .{self.pending_configures},
        );

        if (self.pending_configures > 0) {
            // TODO: log failure to create timer and commit immediately
            self.transaction_timer = c.wl_event_loop_add_timer(
                self.server.wl_event_loop,
                handle_timeout,
                self,
            );
            // Set timeout to 200ms
            if (c.wl_event_source_timer_update(self.transaction_timer, 200) == -1) {
                // TODO: handle failure
            }
        } else {
            self.commitTransaction();
        }
    }

    fn handle_timeout(data: ?*c_void) callconv(.C) c_int {
        const root = @ptrCast(*Root, @alignCast(@alignOf(*Root), data));

        Log.Error.log("Transaction timed out. Some imperfect frames may be shown.", .{});

        root.commitTransaction();

        return 0;
    }

    pub fn notifyConfigured(self: *Self) void {
        self.pending_configures -= 1;
        if (self.pending_configures == 0) {
            // Stop the timer, as we didn't timeout
            if (c.wl_event_source_timer_update(self.transaction_timer, 0) == -1) {
                // TODO: handle failure
            }
            self.commitTransaction();
        }
    }

    /// Apply the pending state and drop stashed buffers. This means that
    /// the next frame drawn will be the post-transaction state of the
    /// layout. Should only be called after all clients have configured for
    /// the new layout. If called early imperfect frames may be drawn.
    fn commitTransaction(self: *Self) void {
        // TODO: apply damage properly

        // Ensure this is set to 0 to avoid entering invalid state (e.g. if called due to timeout)
        self.pending_configures = 0;

        // If there were pending focused tags, make them the current focus
        if (self.pending_focused_tags) |tags| {
            Log.Debug.log(
                "changing current focus: {b:0>10} to {b:0>10}",
                .{ self.current_focused_tags, tags },
            );
            self.current_focused_tags = tags;
            self.pending_focused_tags = null;

            self.focused_view = null;
            self.focusNextView();
        }

        var it = ViewStack.iterator(self.views.first, 0xFFFFFFFF);
        while (it.next()) |view| {
            // Ensure that all pending state is cleared
            view.pending_serial = null;
            if (view.pending_box) |state| {
                view.current_box = state;
                view.pending_box = null;
            }

            // Apply possible pending tags
            if (view.pending_tags) |tags| {
                view.current_tags = tags;
                view.pending_tags = null;

                // If the pending tags caused the currently focused view to no
                // longer be visible, focus the next view.
                if (self.focused_view) |focus| {
                    if (focus == view and
                        view.current_tags & self.current_focused_tags == 0)
                    {
                        self.focusNextView();
                    }
                }
            }

            view.dropStashedBuffer();
        }
    }
};
