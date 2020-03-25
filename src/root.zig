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

    pub fn init(self: *Self, server: *Server) !void {
        self.server = server;

        // Create an output layout, which a wlroots utility for working with an
        // arrangement of screens in a physical layout.
        self.wlr_output_layout = c.wlr_output_layout_create() orelse
            return error.CantCreateWlrOutputLayout;
        errdefer c.wlr_output_layout_destroy(self.wlr_output_layout);

        self.outputs = std.TailQueue(Output).init();
        self.views = std.TailQueue(View).init();
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
        self.views.append(node);
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
};
