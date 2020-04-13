const std = @import("std");
const c = @import("c.zig");

const Cursor = @import("cursor.zig").Cursor;
const Log = @import("log.zig").Log;
const InputManager = @import("input_manager.zig").InputManager;
const Keyboard = @import("keyboard.zig").Keyboard;
const View = @import("view.zig").View;
const ViewStack = @import("view_stack.zig").ViewStack;

pub const Seat = struct {
    const Self = @This();

    input_manager: *InputManager,
    wlr_seat: *c.wlr_seat,

    /// Multiple mice are handled by the same Cursor
    cursor: Cursor,

    /// Mulitple keyboards are handled separately
    keyboards: std.TailQueue(Keyboard),

    /// Currently focused view if any
    focused_view: ?*View,

    /// Stack of views in most recently focused order
    /// If there is a currently focused view, it is on top.
    focus_stack: ViewStack(*View),

    pub fn init(self: *Self, input_manager: *InputManager, name: []const u8) !void {
        self.input_manager = input_manager;

        // This will be automatically destroyed when the display is destroyed
        self.wlr_seat = c.wlr_seat_create(input_manager.server.wl_display, name.ptr) orelse
            return error.CantCreateWlrSeat;

        try self.cursor.init(self);
        errdefer self.cursor.destroy();

        self.keyboards = std.TailQueue(Keyboard).init();

        self.focused_view = null;

        self.focus_stack.init();
    }

    pub fn destroy(self: Self) void {
        self.cursor.destroy();
    }

    /// Set the current focus. If a visible view is passed it will be focused.
    /// If null is passed, the first visible view in the focus stack will be focused.
    pub fn focus(self: *Self, _view: ?*View) void {
        var view = _view;

        // If view is null or not currently visible
        if (if (view) |v| v.current_tags & v.output.current_focused_tags == 0 else true) {
            // Set view to the first currently visible view in the focus stack if any
            view = if (ViewStack(*View).iterator(
                self.focus_stack.first,
                self.input_manager.server.root.focusedOutput().current_focused_tags,
            ).next()) |node| node.view else null;
        }

        if (self.focused_view) |current_focus| {
            // Don't refocus the currently focused view
            if (if (view) |v| current_focus == v else false) {
                return;
            }
            // Deactivate the currently focused view
            current_focus.setActivated(false);
        }

        if (view) |to_focus| {
            // Find or allocate a new node in the focus stack for the target view
            var it = self.focus_stack.first;
            while (it) |node| : (it = node.next) {
                // If the view is found, move it to the top of the stack
                if (node.view == to_focus) {
                    const new_focus_node = self.focus_stack.remove(node);
                    self.focus_stack.push(node);
                    break;
                }
            } else {
                // The view is not in the stack, so allocate a new node and prepend it
                const new_focus_node = self.input_manager.server.allocator.create(
                    ViewStack(*View).Node,
                ) catch unreachable;
                new_focus_node.view = to_focus;
                self.focus_stack.push(new_focus_node);
            }

            // The target view is now at the top of the focus stack, so activate it
            to_focus.setActivated(true);

            // Tell the seat to have the keyboard enter this surface. wlroots will keep
            // track of this and automatically send key events to the appropriate
            // clients without additional work on your part.
            const keyboard: *c.wlr_keyboard = c.wlr_seat_get_keyboard(self.wlr_seat);
            c.wlr_seat_keyboard_notify_enter(
                self.wlr_seat,
                to_focus.wlr_xdg_surface.surface,
                &keyboard.keycodes,
                keyboard.num_keycodes,
                &keyboard.modifiers,
            );
        }

        self.focused_view = view;
    }

    /// Handle the unmapping of a view, removing it from the focus stack and
    /// setting the focus if needed.
    pub fn handleViewUnmap(self: *Self, view: *View) void {
        // Remove the node from the focus stack and destroy it.
        var it = self.focus_stack.first;
        while (it) |node| : (it = node.next) {
            if (node.view == view) {
                self.focus_stack.remove(node);
                self.input_manager.server.allocator.destroy(node);
                break;
            }
        }

        // If the unmapped view is focused, choose a new focus
        if (self.focused_view) |current_focus| {
            if (current_focus == view) {
                self.focus(null);
            }
        }
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
