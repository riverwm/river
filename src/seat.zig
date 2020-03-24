const std = @import("std");
const c = @import("c.zig").c;

const Cursor = @import("cursor.zig").Cursor;
const Keyboard = @import("keyboard.zig").Keyboard;
const Server = @import("server.zig").Server;

// TODO: InputManager and multi-seat support
pub const Seat = struct {
    server: *Server,
    wlr_seat: *c.wlr_seat,
    listen_new_input: c.wl_listener,

    // Multiple mice are handled by the same Cursor
    cursor: Cursor,
    // Mulitple keyboards are handled separately
    keyboards: std.TailQueue(Keyboard),

    pub fn create(server: *Server) !@This() {
        var seat = @This(){
            .server = server,
            .wlr_seat = undefined,
            .listen_new_input = c.wl_listener{
                .link = undefined,
                .notify = handle_new_input,
            },
            .cursor = undefined,
            .keyboards = std.TailQueue(Keyboard).init(),
        };

        // This seems to be the default seat name used by compositors
        seat.wlr_seat = c.wlr_seat_create(server.wl_display, "seat0") orelse
            return error.CantCreateWlrSeat;

        return seat;
    }

    pub fn init(self: *@This()) !void {
        self.cursor = try Cursor.create(self);
        self.cursor.init();

        // Set up handler for all new input devices made available. This
        // includes keyboards, pointers, touch, etc.
        c.wl_signal_add(&self.server.wlr_backend.events.new_input, &self.listen_new_input);
    }

    fn add_keyboard(self: *@This(), device: *c.wlr_input_device) !void {
        c.wlr_seat_set_keyboard(self.wlr_seat, device);

        var node = try self.keyboards.allocateNode(self.server.allocator);
        try node.data.init(self, device);
        self.keyboards.append(node);
    }

    fn add_pointer(self: *@This(), device: *c.struct_wlr_input_device) void {
        // We don't do anything special with pointers. All of our pointer handling
        // is proxied through wlr_cursor. On another compositor, you might take this
        // opportunity to do libinput configuration on the device to set
        // acceleration, etc.
        c.wlr_cursor_attach_input_device(self.cursor.wlr_cursor, device);
    }

    fn handle_new_input(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is raised by the backend when a new input device becomes available.
        var seat = @fieldParentPtr(Seat, "listen_new_input", listener.?);
        var device = @ptrCast(*c.wlr_input_device, @alignCast(@alignOf(*c.wlr_input_device), data));

        switch (device.type) {
            .WLR_INPUT_DEVICE_KEYBOARD => seat.add_keyboard(device) catch unreachable,
            .WLR_INPUT_DEVICE_POINTER => seat.add_pointer(device),
            else => {},
        }

        // We need to let the wlr_seat know what our capabilities are, which is
        // communiciated to the client. In TinyWL we always have a cursor, even if
        // there are no pointer devices, so we always include that capability.
        var caps: u32 = @intCast(u32, c.WL_SEAT_CAPABILITY_POINTER);
        // if list not empty
        if (seat.keyboards.len > 0) {
            caps |= @intCast(u32, c.WL_SEAT_CAPABILITY_KEYBOARD);
        }
        c.wlr_seat_set_capabilities(seat.wlr_seat, caps);
    }
};
