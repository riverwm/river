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
const command = @import("command.zig");
const util = @import("util.zig");

const Cursor = @import("Cursor.zig");
const InputManager = @import("InputManager.zig");
const Keyboard = @import("Keyboard.zig");
const LayerSurface = @import("LayerSurface.zig");
const Output = @import("Output.zig");
const SeatStatus = @import("SeatStatus.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;

// TODO: remove none variant, unify focused_view and focused_layer fields
// with type ?FocusTarget
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

/// ID of the current keymap mode
mode_id: usize,

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

/// List of status tracking objects relaying changes to this seat to clients.
status_trackers: std.SinglyLinkedList(SeatStatus),

listen_request_set_selection: c.wl_listener,

pub fn init(self: *Self, input_manager: *InputManager, name: []const u8) !void {
    self.input_manager = input_manager;

    // This will be automatically destroyed when the display is destroyed
    self.wlr_seat = c.wlr_seat_create(input_manager.server.wl_display, name.ptr) orelse return error.OutOfMemory;
    self.wlr_seat.data = self;

    try self.cursor.init(self);
    errdefer self.cursor.deinit();

    self.keyboards = std.TailQueue(Keyboard).init();

    self.mode_id = 0;

    self.focused_output = &self.input_manager.server.root.noop_output;

    self.focused_view = null;

    self.focus_stack.init();

    self.focused_layer = null;

    self.status_trackers = std.SinglyLinkedList(SeatStatus).init();

    self.listen_request_set_selection.notify = handleRequestSetSelection;
    c.wl_signal_add(&self.wlr_seat.events.request_set_selection, &self.listen_request_set_selection);
}

pub fn deinit(self: *Self) void {
    self.cursor.deinit();

    while (self.keyboards.pop()) |node| util.gpa.destroy(node);

    while (self.focus_stack.first) |node| {
        self.focus_stack.remove(node);
        util.gpa.destroy(node);
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
            const new_focus_node = util.gpa.create(
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
    }) return;

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

    // Inform any clients tracking status of the change
    var it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendFocusedView();
}

/// Focus the given output, notifying any listening clients of the change.
pub fn focusOutput(self: *Self, output: *Output) void {
    const root = &self.input_manager.server.root;

    var it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendOutput(.unfocused);

    self.focused_output = output;

    it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendOutput(.focused);
}

/// Handle the unmapping of a view, removing it from the focus stack and
/// setting the focus if needed.
pub fn handleViewUnmap(self: *Self, view: *View) void {
    // Remove the node from the focus stack and destroy it.
    var it = self.focus_stack.first;
    while (it) |node| : (it = node.next) {
        if (node.view == view) {
            self.focus_stack.remove(node);
            util.gpa.destroy(node);
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

/// Handle any user-defined mapping for the passed keysym and modifiers
/// Returns true if the key was handled
pub fn handleMapping(self: *Self, keysym: c.xkb_keysym_t, modifiers: u32) bool {
    const modes = &self.input_manager.server.config.modes;
    for (modes.items[self.mode_id].items) |mapping| {
        if (modifiers == mapping.modifiers and keysym == mapping.keysym) {
            // Execute the bound command
            var failure_message: []const u8 = undefined;
            command.run(util.gpa, self, mapping.command_args, &failure_message) catch |err| {
                // TODO: log the error
                if (err == command.Error.CommandFailed)
                    util.gpa.free(failure_message);
            };
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

    const node = try util.gpa.create(std.TailQueue(Keyboard).Node);
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
    const event = util.voidCast(c.wlr_seat_request_set_selection_event, data.?);
    c.wlr_seat_set_selection(self.wlr_seat, event.source, event.serial);
}
