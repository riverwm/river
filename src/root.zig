const std = @import("std");
const c = @import("c.zig").c;

const Output = @import("output.zig").Output;
const Server = @import("server.zig").Server;
const Seat = @import("seat.zig").Seat;
const View = @import("view.zig").View;

/// Responsible for all windowing operations
pub const Root = struct {
    const Self = @This();

    server: *Server,

    wlr_output_layout: *c.wlr_output_layout,
    outputs: std.TailQueue(Output),

    // Must stay ordered, first N views in list are the masters
    views: std.TailQueue(View),
    unmapped_views: std.TailQueue(View),

    // Number of pending configures sent in the current transaction.
    // A value of 0 means there is no current transaction.
    pending_count: u32,

    pub fn init(self: *Self, server: *Server) !void {
        self.server = server;
        self.pending_count = 0;

        // Create an output layout, which a wlroots utility for working with an
        // arrangement of screens in a physical layout.
        self.wlr_output_layout = c.wlr_output_layout_create() orelse
            return error.CantCreateWlrOutputLayout;
        errdefer c.wlr_output_layout_destroy(self.wlr_output_layout);

        self.outputs = std.TailQueue(Output).init();
        self.views = std.TailQueue(View).init();
        self.unmapped_views = std.TailQueue(View).init();
    }

    pub fn destroy(self: *Self) void {
        c.wlr_output_layout_destroy(self.wlr_output_layout);
    }

    pub fn addOutput(self: *Self, wlr_output: *c.wlr_output) void {
        // TODO: Handle failure
        const node = self.outputs.allocateNode(self.server.allocator) catch unreachable;
        node.data.init(self, wlr_output) catch unreachable;
        self.outputs.append(node);
    }

    pub fn addView(self: *Self, wlr_xdg_surface: *c.wlr_xdg_surface) void {
        const node = self.views.allocateNode(self.server.allocator) catch unreachable;
        node.data.init(self, wlr_xdg_surface);
        self.unmapped_views.append(node);
    }

    /// Finds the top most view under the output layout coordinates lx, ly
    /// returns the view if found, and a pointer to the wlr_surface as well as the surface coordinates
    pub fn viewAt(self: *Self, lx: f64, ly: f64, surface: *?*c.wlr_surface, sx: *f64, sy: *f64) ?*View {
        var it = self.views.last;
        while (it) |node| : (it = node.prev) {
            if (node.data.isAt(lx, ly, surface, sx, sy)) {
                return &node.data;
            }
        }
        return null;
    }

    pub fn arrange(self: *Self) void {
        if (self.views.len == 0) {
            return;
        }
        // Super basic vertical layout for now, no master/slave stuff
        // This can't return null if pass null as the reference
        const output_box: *c.wlr_box = c.wlr_output_layout_get_box(self.wlr_output_layout, null);
        const new_height = output_box.height;
        // Allow for a 10px gap
        const num_views = @intCast(c_int, self.views.len);
        const new_width = @divTrunc(output_box.width, num_views) - (num_views - 1) * 10;

        var x: c_int = 0;
        var y: c_int = 0;

        var it = self.views.first;
        while (it) |node| : (it = node.next) {
            const view = &node.data;
            view.pending_state.x = x;
            view.pending_state.y = y;
            view.pending_state.width = @intCast(u32, new_width);
            view.pending_state.height = @intCast(u32, new_height);

            x += new_width + 10;
        }

        self.startTransaction();
    }

    /// Initiate an atomic change to the layout. This change will not be
    /// applied until all affected clients ack a configure and commit a buffer.
    fn startTransaction(self: *Self) void {
        std.debug.assert(self.pending_count == 0);

        var it = self.views.first;
        while (it) |node| : (it = node.next) {
            const view = &node.data;
            if (view.needsConfigure()) {
                view.configurePending();
                self.pending_count += 1;

                // We save the current buffer, so we can send an early
                // frame done event to give the client a head start on
                // redrawing.
                view.sendFrameDone();
            }
            view.stashBuffer();
        }

        // TODO: start a timer and handle timeout waiting for all clients to ack
    }

    pub fn notifyConfigured(self: *Self) void {
        self.pending_count -= 1;
        if (self.pending_count == 0) {
            self.commitTransaction();
        }
    }

    /// Apply the pending state and drop stashed buffers. This means that
    /// the next frame drawn will be the post-transaction state of the
    /// layout. Must only be called after all clients have configured for
    /// the new layout.
    fn commitTransaction(self: *Self) void {
        // TODO: apply damage properly
        var it = self.views.first;
        while (it) |node| : (it = node.next) {
            const view = &node.data;

            // TODO: handle views that timed out
            view.current_state = view.pending_state;
            view.dropStashedBuffer();
        }
    }
};
