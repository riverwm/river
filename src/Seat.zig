// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
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

const c = @import("c.zig");

const Cursor = @import("Cursor.zig");
const InputManager = @import("InputManager.zig");
const Keyboard = @import("Keyboard.zig");
const LayerSurface = @import("LayerSurface.zig");
const Mode = @import("Mode.zig");
const Output = @import("Output.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;

const FocusTarget = union(enum) {
    view: *View,
    layer: *LayerSurface,
    none: void,
};

input_manager: *InputManager,
wlr_seat: *c.wlr_seat,

/// Multiple mice are handled by the same Cursor
cursor: Cursor,

/// Mulitple keyboards are handled separately
keyboards: std.TailQueue(Keyboard),

/// Current keybind mode
mode: *Mode,

/// Currently focused output, may be the noop output if no
focused_output: *Output,

/// Currently focused view if any
focused_view: ?*View,

/// Stack of views in most recently focused order
/// If there is a currently focused view, it is on top.
focus_stack: ViewStack(*View),

/// Currently focused layer, if any. While this is non-null, no views may
/// recieve focus.
focused_layer: ?*LayerSurface,

listen_request_set_selection: c.wl_listener,

pub fn init(self: *Self, input_manager: *InputManager, name: []const u8) !void {
    self.input_manager = input_manager;

    // This will be automatically destroyed when the display is destroyed
    self.wlr_seat = c.wlr_seat_create(input_manager.server.wl_display, name.ptr) orelse
        return error.CantCreateWlrSeat;

    try self.cursor.init(self);
    errdefer self.cursor.destroy();

    self.keyboards = std.TailQueue(Keyboard).init();

    self.mode = input_manager.server.config.getMode("normal");

    self.focused_output = &self.input_manager.server.root.noop_output;

    self.focused_view = null;

    self.focus_stack.init();

    self.focused_layer = null;

    self.listen_request_set_selection.notify = handleRequestSetSelection;
    c.wl_signal_add(&self.wlr_seat.events.request_set_selection, &self.listen_request_set_selection);
}

pub fn deinit(self: *Self) void {
    self.cursor.deinit();

    while (self.keyboards.pop()) |node| {
        self.input_manager.server.allocator.destroy(node);
    }

    while (self.focus_stack.first) |node| {
        self.focus_stack.remove(node);
        self.input_manager.server.allocator.destroy(node);
    }
}

/// Set the current focus. If a visible view is passed it will be focused.
/// If null is passed, the first visible view in the focus stack will be focused.
pub fn focus(self: *Self, _view: ?*View) void {
    var view = _view;

    // While a layer surface is focused, views may not recieve focus
    if (self.focused_layer != null) {
        std.debug.assert(self.focused_view == null);
        return;
    }

    // If view is null or not currently visible
    if (if (view) |v|
        v.output != self.focused_output or
            v.current_tags & self.focused_output.current_focused_tags == 0
    else
        true) {
        // Set view to the first currently visible view on in the focus stack if any
        var it = ViewStack(*View).iterator(
            self.focus_stack.first,
            self.focused_output.current_focused_tags,
        );
        view = while (it.next()) |node| {
            if (node.view.output == self.focused_output) {
                break node.view;
            }
        } else null;
    }

    if (view) |view_to_focus| {
        // Find or allocate a new node in the focus stack for the target view
        var it = self.focus_stack.first;
        while (it) |node| : (it = node.next) {
            // If the view is found, move it to the top of the stack
            if (node.view == view_to_focus) {
                const new_focus_node = self.focus_stack.remove(node);
                self.focus_stack.push(node);
                break;
            }
        } else {
            // The view is not in the stack, so allocate a new node and prepend it
            const new_focus_node = self.input_manager.server.allocator.create(
                ViewStack(*View).Node,
            ) catch unreachable;
            new_focus_node.view = view_to_focus;
            self.focus_stack.push(new_focus_node);
        }

        // Focus the target view
        self.setFocusRaw(.{ .view = view_to_focus });
    } else {
        // Otherwise clear the focus
        self.setFocusRaw(.{ .none = {} });
    }
}

/// Switch focus to the target, handling unfocus and input inhibition
/// properly. This should only be called directly if dealing with layers.
pub fn setFocusRaw(self: *Self, focus_target: FocusTarget) void {
    // If the target is already focused, do nothing
    if (switch (focus_target) {
        .view => |target_view| target_view == self.focused_view,
        .layer => |target_layer| target_layer == self.focused_layer,
        .none => false,
    }) {
        return;
    }

    // Obtain the target wlr_surface
    const target_wlr_surface = switch (focus_target) {
        .view => |target_view| target_view.wlr_surface.?,
        .layer => |target_layer| target_layer.wlr_layer_surface.surface.?,
        .none => null,
    };

    // If input is not allowed on the target surface (e.g. due to an active
    // input inhibitor) do not set focus. If there is no target surface we
    // still clear the focus.
    if (if (target_wlr_surface) |wlr_surface|
        self.input_manager.inputAllowed(wlr_surface)
    else
        true) {
        // First clear the current focus
        if (self.focused_view) |current_focus| {
            std.debug.assert(self.focused_layer == null);
            current_focus.setFocused(false);
            self.focused_view = null;
        }
        if (self.focused_layer) |current_focus| {
            std.debug.assert(self.focused_view == null);
            self.focused_layer = null;
        }
        c.wlr_seat_keyboard_clear_focus(self.wlr_seat);

        // Set the new focus
        switch (focus_target) {
            .view => |target_view| {
                std.debug.assert(self.focused_output == target_view.output);
                target_view.setFocused(true);
                self.focused_view = target_view;
            },
            .layer => |target_layer| blk: {
                std.debug.assert(self.focused_output == target_layer.output);
                self.focused_layer = target_layer;
            },
            .none => {},
        }

        // Tell wlroots to send the new keyboard focus if we have a target
        if (target_wlr_surface) |wlr_surface| {
            const keyboard: *c.wlr_keyboard = c.wlr_seat_get_keyboard(self.wlr_seat);
            c.wlr_seat_keyboard_notify_enter(
                self.wlr_seat,
                wlr_surface,
                &keyboard.keycodes,
                keyboard.num_keycodes,
                &keyboard.modifiers,
            );
        }
    }
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
    for (self.mode.keybinds.items) |keybind| {
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
    var caps = @intCast(u32, c.WL_SEAT_CAPABILITY_POINTER);
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

fn handleRequestSetSelection(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_request_set_selection", listener.?);
    const event = @ptrCast(
        *c.wlr_seat_request_set_selection_event,
        @alignCast(@alignOf(*c.wlr_seat_request_set_selection_event), data),
    );
    c.wlr_seat_set_selection(self.wlr_seat, event.source, event.serial);
}
