const std = @import("std");
const c = @import("c.zig");

const Log = @import("log.zig").Log;
const Seat = @import("seat.zig").Seat;
const Server = @import("server.zig").Server;

pub const InputManager = struct {
    const Self = @This();

    const default_seat_name = "default";

    server: *Server,

    wlr_input_inhibit_manager: *c.wlr_input_inhibit_manager,

    seats: std.TailQueue(Seat),
    default_seat: *Seat,

    exclusive_client: ?*c.wl_client,

    listen_inhibit_activate: c.wl_listener,
    listen_inhibit_deactivate: c.wl_listener,
    listen_new_input: c.wl_listener,

    pub fn init(self: *Self, server: *Server) !void {
        self.server = server;

        // This is automatically freed when the display is destroyed
        self.wlr_input_inhibit_manager =
            c.wlr_input_inhibit_manager_create(server.wl_display) orelse
            return error.CantCreateInputInhibitManager;

        self.seats = std.TailQueue(Seat).init();

        const seat_node = try server.allocator.create(std.TailQueue(Seat).Node);
        try seat_node.data.init(self, default_seat_name);
        self.default_seat = &seat_node.data;
        self.seats.prepend(seat_node);

        self.exclusive_client = null;

        // Set up all listeners
        self.listen_inhibit_activate.notify = handleInhibitActivate;
        c.wl_signal_add(
            &self.wlr_input_inhibit_manager.events.activate,
            &self.listen_inhibit_activate,
        );

        self.listen_inhibit_deactivate.notify = handleInhibitDeactivate;
        c.wl_signal_add(
            &self.wlr_input_inhibit_manager.events.deactivate,
            &self.listen_inhibit_deactivate,
        );

        self.listen_new_input.notify = handleNewInput;
        c.wl_signal_add(&self.server.wlr_backend.events.new_input, &self.listen_new_input);
    }

    pub fn deinit(self: *Self) void {
        while (self.seats.pop()) |seat_node| {
            seat_node.data.deinit();
            self.server.allocator.destroy(seat_node);
        }
    }

    /// Must be called whenever a view is unmapped.
    pub fn handleViewUnmap(self: Self, view: *View) void {
        var it = self.seats.first;
        while (it) |node| : (it = node.next) {
            const seat = &node.data;
            seat.handleViewUnmap(view);
        }
    }

    /// Returns true if input is currently allowed on the passed surface.
    pub fn inputAllowed(self: Self, wlr_surface: *c.wlr_surface) bool {
        return if (self.exclusive_client) |exclusive_client|
            exclusive_client == c.wl_resource_get_client(wlr_surface.resource)
        else
            true;
    }

    fn handleInhibitActivate(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const self = @fieldParentPtr(Self, "listen_inhibit_activate", listener.?);

        Log.Debug.log("Input inhibitor activated", .{});

        // Clear focus of all seats
        var seat_it = self.seats.first;
        while (seat_it) |seat_node| : (seat_it = seat_node.next) {
            seat_node.data.setFocusRaw(.{ .none = {} });
        }

        self.exclusive_client = self.wlr_input_inhibit_manager.active_client;
    }

    fn handleInhibitDeactivate(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const self = @fieldParentPtr(Self, "listen_inhibit_deactivate", listener.?);

        Log.Debug.log("Input inhibitor deactivated", .{});

        self.exclusive_client = null;

        // Calling arrangeLayers() like this ensures that any top or overlay,
        // keyboard-interactive surfaces will re-grab focus.
        var output_it = self.server.root.outputs.first;
        while (output_it) |output_node| : (output_it = output_node.next) {
            output_node.data.arrangeLayers();
        }

        // After ensuring that any possible layer surface focus grab has occured,
        // have each Seat handle focus.
        var seat_it = self.seats.first;
        while (seat_it) |seat_node| : (seat_it = seat_node.next) {
            seat_node.data.focus(null);
        }
    }

    /// This event is raised by the backend when a new input device becomes available.
    fn handleNewInput(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const self = @fieldParentPtr(Self, "listen_new_input", listener.?);
        const device = @ptrCast(*c.wlr_input_device, @alignCast(@alignOf(*c.wlr_input_device), data));

        // TODO: suport multiple seats
        if (self.seats.first) |seat_node| {
            seat_node.data.addDevice(device) catch unreachable;
        }
    }
};
