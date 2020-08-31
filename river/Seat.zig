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

const build_options = @import("build_options");
const std = @import("std");

const c = @import("c.zig");
const command = @import("command.zig");
const log = @import("log.zig");
const util = @import("util.zig");

const DragIcon = @import("DragIcon.zig");
const Cursor = @import("Cursor.zig");
const InputManager = @import("InputManager.zig");
const Keyboard = @import("Keyboard.zig");
const LayerSurface = @import("LayerSurface.zig");
const Output = @import("Output.zig");
const SeatStatus = @import("SeatStatus.zig");
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
cursor: Cursor = undefined,

/// Mulitple keyboards are handled separately
keyboards: std.TailQueue(Keyboard) = .{},

/// ID of the current keymap mode
mode_id: usize = 0,

/// Currently focused output, may be the noop output if no
focused_output: *Output,

/// Currently focused view/layer surface if any
focused: FocusTarget = .none,

/// Stack of views in most recently focused order
/// If there is a currently focused view, it is on top.
focus_stack: ViewStack(*View) = .{},

/// List of status tracking objects relaying changes to this seat to clients.
status_trackers: std.SinglyLinkedList(SeatStatus) = .{},

listen_request_set_selection: c.wl_listener = undefined,
listen_request_start_drag: c.wl_listener = undefined,
listen_start_drag: c.wl_listener = undefined,

pub fn init(self: *Self, input_manager: *InputManager, name: [*:0]const u8) !void {
    self.* = .{
        .input_manager = input_manager,
        // This will be automatically destroyed when the display is destroyed
        .wlr_seat = c.wlr_seat_create(input_manager.server.wl_display, name) orelse return error.OutOfMemory,
        .focused_output = &self.input_manager.server.root.noop_output,
    };
    self.wlr_seat.data = self;

    try self.cursor.init(self);

    self.listen_request_set_selection.notify = handleRequestSetSelection;
    c.wl_signal_add(&self.wlr_seat.events.request_set_selection, &self.listen_request_set_selection);

    self.listen_request_start_drag.notify = handleRequestStartDrag;
    c.wl_signal_add(&self.wlr_seat.events.request_start_drag, &self.listen_request_start_drag);

    self.listen_start_drag.notify = handleStartDrag;
    c.wl_signal_add(&self.wlr_seat.events.start_drag, &self.listen_start_drag);
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
pub fn focus(self: *Self, _target: ?*View) void {
    var target = _target;

    // While a layer surface is focused, views may not recieve focus
    if (self.focused == .layer) return;

    // If the view is not currently visible, behave as if null was passed
    if (target) |view| {
        if (view.output != self.focused_output or
            view.pending.tags & self.focused_output.pending.tags == 0) target = null;
    }

    // If the target view is not fullscreen or null, then a fullscreen view
    // will grab focus if visible.
    if (if (target) |v| !v.pending.fullscreen else true) {
        const tags = self.focused_output.pending.tags;
        var it = ViewStack(*View).iter(self.focus_stack.first, .forward, tags, pendingFilter);
        target = while (it.next()) |view| {
            if (view.output == self.focused_output and view.pending.fullscreen) break view;
        } else target;
    }

    if (target == null) {
        // Set view to the first currently visible view in the focus stack if any
        const tags = self.focused_output.pending.tags;
        var it = ViewStack(*View).iter(self.focus_stack.first, .forward, tags, pendingFilter);
        target = while (it.next()) |view| {
            if (view.output == self.focused_output) break view;
        } else null;
    }

    if (target) |view| {
        // Find or allocate a new node in the focus stack for the target view
        var it = self.focus_stack.first;
        while (it) |node| : (it = node.next) {
            // If the view is found, move it to the top of the stack
            if (node.view == view) {
                const new_focus_node = self.focus_stack.remove(node);
                self.focus_stack.push(node);
                break;
            }
        } else {
            // The view is not in the stack, so allocate a new node and prepend it
            const new_focus_node = util.gpa.create(ViewStack(*View).Node) catch return;
            new_focus_node.view = view;
            self.focus_stack.push(new_focus_node);
        }

        // Focus the target view
        self.setFocusRaw(.{ .view = view });
    } else {
        // Otherwise clear the focus
        self.setFocusRaw(.{ .none = {} });
    }
}

fn pendingFilter(view: *View, filter_tags: u32) bool {
    return !view.destroying and view.pending.tags & filter_tags != 0;
}

/// Switch focus to the target, handling unfocus and input inhibition
/// properly. This should only be called directly if dealing with layers.
pub fn setFocusRaw(self: *Self, new_focus: FocusTarget) void {
    // If the target is already focused, do nothing
    if (std.meta.eql(new_focus, self.focused)) return;

    // Obtain the target wlr_surface
    const target_wlr_surface = switch (new_focus) {
        .view => |target_view| target_view.wlr_surface.?,
        .layer => |target_layer| target_layer.wlr_layer_surface.surface.?,
        .none => null,
    };

    // If input is not allowed on the target surface (e.g. due to an active
    // input inhibitor) do not set focus. If there is no target surface we
    // still clear the focus.
    if (if (target_wlr_surface) |wlr_surface| self.input_manager.inputAllowed(wlr_surface) else true) {
        // First clear the current focus
        if (self.focused == .view) {
            self.focused.view.pending.focus -= 1;
            // This is needed because xwayland views don't double buffer
            // activated state.
            if (build_options.xwayland and self.focused.view.impl == .xwayland_view)
                c.wlr_xwayland_surface_activate(self.focused.view.impl.xwayland_view.wlr_xwayland_surface, false);
        }
        c.wlr_seat_keyboard_clear_focus(self.wlr_seat);

        // Set the new focus
        switch (new_focus) {
            .view => |target_view| {
                std.debug.assert(self.focused_output == target_view.output);
                target_view.pending.focus += 1;
                // This is needed because xwayland views don't double buffer
                // activated state.
                if (build_options.xwayland and target_view.impl == .xwayland_view)
                    c.wlr_xwayland_surface_activate(target_view.impl.xwayland_view.wlr_xwayland_surface, true);
            },
            .layer => |target_layer| std.debug.assert(self.focused_output == target_layer.output),
            .none => {},
        }
        self.focused = new_focus;

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

pub fn handleActivity(self: Self) void {
    c.wlr_idle_notify_activity(self.input_manager.wlr_idle, self.wlr_seat);
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

    self.cursor.handleViewUnmap(view);

    // If the unmapped view is focused, choose a new focus
    if (self.focused == .view and self.focused.view == view) self.focus(null);
}

/// Handle any user-defined mapping for the passed keysym and modifiers
/// Returns true if the key was handled
pub fn handleMapping(self: *Self, keysym: c.xkb_keysym_t, modifiers: u32, released: bool) bool {
    const modes = &self.input_manager.server.config.modes;
    for (modes.items[self.mode_id].mappings.items) |mapping| {
        if (modifiers == mapping.modifiers and keysym == mapping.keysym and released == mapping.release) {
            // Execute the bound command
            const args = mapping.command_args;
            var out: ?[]const u8 = null;
            defer if (out) |s| util.gpa.free(s);
            command.run(util.gpa, self, args, &out) catch |err| {
                const failure_message = switch (err) {
                    command.Error.Other => out.?,
                    else => command.errToMsg(err),
                };
                log.err(.command, "{}: {}", .{ args[0], failure_message });
                return true;
            };
            if (out) |s| {
                const stdout = std.io.getStdOut().outStream();
                stdout.print("{}", .{s}) catch
                    |err| log.err(.command, "{}: write to stdout failed {}", .{ args[0], err });
            }
            return true;
        }
    }
    return false;
}

/// Add a newly created input device to the seat and update the reported
/// capabilities.
pub fn addDevice(self: *Self, device: *c.wlr_input_device) void {
    switch (device.type) {
        .WLR_INPUT_DEVICE_KEYBOARD => self.addKeyboard(device) catch return,
        .WLR_INPUT_DEVICE_POINTER => self.addPointer(device),
        else => return,
    }

    // We need to let the wlr_seat know what our capabilities are, which is
    // communiciated to the client. We always have a cursor, even if
    // there are no pointer devices, so we always include that capability.
    var caps = @intCast(u32, c.WL_SEAT_CAPABILITY_POINTER);
    if (self.keyboards.len > 0) caps |= @intCast(u32, c.WL_SEAT_CAPABILITY_KEYBOARD);
    c.wlr_seat_set_capabilities(self.wlr_seat, caps);
}

fn addKeyboard(self: *Self, device: *c.wlr_input_device) !void {
    const node = try util.gpa.create(std.TailQueue(Keyboard).Node);
    node.data.init(self, device) catch |err| {
        switch (err) {
            error.XkbContextFailed => log.err(.keyboard, "Failed to create XKB context", .{}),
            error.XkbKeymapFailed => log.err(.keyboard, "Failed to create XKB keymap", .{}),
            error.SetKeymapFailed => log.err(.keyboard, "Failed to set wlr keyboard keymap", .{}),
        }
        return;
    };
    self.keyboards.append(node);
    c.wlr_seat_set_keyboard(self.wlr_seat, device);
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

fn handleRequestStartDrag(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_request_start_drag", listener.?);
    const event = util.voidCast(c.wlr_seat_request_start_drag_event, data.?);

    if (c.wlr_seat_validate_pointer_grab_serial(self.wlr_seat, event.origin, event.serial)) {
        log.debug(.seat, "starting pointer drag", .{});
        c.wlr_seat_start_pointer_drag(self.wlr_seat, event.drag, event.serial);
        return;
    }

    log.debug(.seat, "ignoring request to start drag, failed to validate serial {}", .{event.serial});
    c.wlr_data_source_destroy(event.drag.*.source);
}

fn handleStartDrag(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_start_drag", listener.?);
    const wlr_drag = util.voidCast(c.wlr_drag, data.?);

    if (wlr_drag.icon) |wlr_drag_icon| {
        const node = util.gpa.create(std.SinglyLinkedList(DragIcon).Node) catch {
            log.crit(.seat, "out of memory", .{});
            return;
        };
        node.data.init(self, wlr_drag_icon);
        self.input_manager.server.root.drag_icons.prepend(node);
    }
    self.cursor.mode = .passthrough;
}
