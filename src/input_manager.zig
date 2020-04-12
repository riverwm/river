const std = @import("std");
const c = @import("c.zig");

const Seat = @import("seat.zig").Seat;
const Server = @import("server.zig").Server;

pub const InputManager = struct {
    const Self = @This();

    const default_seat = "seat0";

    server: *Server,

    seats: std.TailQueue(Seat),

    listen_new_input: c.wl_listener,

    pub fn init(self: *Self, server: *Server) !void {
        self.server = server;

        self.seats = std.TailQueue(Seat).init();

        const seat_node = try server.allocator.create(std.TailQueue(Seat).Node);
        try seat_node.data.init(self, default_seat);
        self.seats.prepend(seat_node);

        // Set up handler for all new input devices made available. This
        // includes keyboards, pointers, touch, etc.
        self.listen_new_input.notify = handleNewInput;
        c.wl_signal_add(&self.server.wlr_backend.events.new_input, &self.listen_new_input);
    }

    /// This event is raised by the backend when a new input device becomes available.
    fn handleNewInput(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const input_manager = @fieldParentPtr(InputManager, "listen_new_input", listener.?);
        const device = @ptrCast(*c.wlr_input_device, @alignCast(@alignOf(*c.wlr_input_device), data));

        // TODO: suport multiple seats
        if (input_manager.seats.first) |seat_node| {
            seat_node.data.addDevice(device) catch unreachable;
        }
    }
};
