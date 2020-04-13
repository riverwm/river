const std = @import("std");
const c = @import("c.zig");

const Cursor = @import("cursor.zig").Cursor;
const InputManager = @import("input_manager.zig").InputManager;
const Keyboard = @import("keyboard.zig").Keyboard;

pub const Seat = struct {
    const Self = @This();

    input_manager: *InputManager,
    wlr_seat: *c.wlr_seat,

    /// Multiple mice are handled by the same Cursor
    cursor: Cursor,

    /// Mulitple keyboards are handled separately
    keyboards: std.TailQueue(Keyboard),

    pub fn init(self: *Self, input_manager: *InputManager, name: []const u8) !void {
        self.input_manager = input_manager;

        // This will be automatically destroyed when the display is destroyed
        self.wlr_seat = c.wlr_seat_create(input_manager.server.wl_display, name.ptr) orelse
            return error.CantCreateWlrSeat;

        try self.cursor.init(self);
        errdefer self.cursor.destroy();

        self.keyboards = std.TailQueue(Keyboard).init();
    }

    pub fn destroy(self: Self) void {
        self.cursor.destroy();
    }

    /// Handle any user-defined keybinding for the passed keysym and modifiers
    /// Returns true if the key was handled
    pub fn handleKeybinding(self: *Self, keysym: c.xkb_keysym_t, modifiers: u32) bool {
        for (self.input_manager.server.config.keybinds.items) |keybind| {
            if (modifiers == keybind.modifiers and keysym == keybind.keysym) {
                // Execute the bound command
                keybind.command(self, keybind.arg);
                return true;
            }
        }
        return false;
    }

    /// Add a newly created input device to the seat and update the reported
    /// capabilities.
    pub fn addDevice(self: *Self, device: *c.wlr_input_device) !void {
        switch (device.type) {
            .WLR_INPUT_DEVICE_KEYBOARD => self.addKeyboard(device) catch unreachable,
            .WLR_INPUT_DEVICE_POINTER => self.addPointer(device),
            else => {},
        }

        // We need to let the wlr_seat know what our capabilities are, which is
        // communiciated to the client. We always have a cursor, even if
        // there are no pointer devices, so we always include that capability.
        var caps: u32 = @intCast(u32, c.WL_SEAT_CAPABILITY_POINTER);
        // if list not empty
        if (self.keyboards.len > 0) {
            caps |= @intCast(u32, c.WL_SEAT_CAPABILITY_KEYBOARD);
        }
        c.wlr_seat_set_capabilities(self.wlr_seat, caps);
    }

    fn addKeyboard(self: *Self, device: *c.wlr_input_device) !void {
        c.wlr_seat_set_keyboard(self.wlr_seat, device);

        const node = try self.keyboards.allocateNode(self.input_manager.server.allocator);
        try node.data.init(self, device);
        self.keyboards.append(node);
    }

    fn addPointer(self: Self, device: *c.struct_wlr_input_device) void {
        // We don't do anything special with pointers. All of our pointer handling
        // is proxied through wlr_cursor. On another compositor, you might take this
        // opportunity to do libinput configuration on the device to set
        // acceleration, etc.
        c.wlr_cursor_attach_input_device(self.cursor.wlr_cursor, device);
    }
};
