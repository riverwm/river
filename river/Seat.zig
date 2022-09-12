// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
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
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");

const command = @import("command.zig");
const server = &@import("main.zig").server;
const util = @import("util.zig");

const Cursor = @import("Cursor.zig");
const DragIcon = @import("DragIcon.zig");
const InputDevice = @import("InputDevice.zig");
const InputManager = @import("InputManager.zig");
const Keyboard = @import("Keyboard.zig");
const KeycodeSet = @import("KeycodeSet.zig");
const LayerSurface = @import("LayerSurface.zig");
const Mapping = @import("Mapping.zig");
const Output = @import("Output.zig");
const SeatStatus = @import("SeatStatus.zig");
const Switch = @import("Switch.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");

const log = std.log.scoped(.seat);
const PointerConstraint = @import("PointerConstraint.zig");

const FocusTarget = union(enum) {
    view: *View,
    xwayland_override_redirect: *XwaylandOverrideRedirect,
    layer: *LayerSurface,
    none: void,
};

wlr_seat: *wlr.Seat,

/// Multiple mice are handled by the same Cursor
cursor: Cursor = undefined,

/// ID of the current keymap mode
mode_id: u32 = 0,

/// ID of previous keymap mode, used when returning from "locked" mode
prev_mode_id: u32 = 0,

/// Timer for repeating keyboard mappings
mapping_repeat_timer: *wl.EventSource,

/// Currently repeating mapping, if any
repeating_mapping: ?*const Mapping = null,

/// Currently focused output, may be the noop output if no real output
/// is currently available for focus.
focused_output: *Output,

/// Currently focused view/layer surface if any
focused: FocusTarget = .none,

/// Stack of views in most recently focused order
/// If there is a currently focused view, it is on top.
focus_stack: ViewStack(*View) = .{},

/// List of status tracking objects relaying changes to this seat to clients.
status_trackers: std.SinglyLinkedList(SeatStatus) = .{},

/// True if a pointer drag is currently in progress
pointer_drag: bool = false,

request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) =
    wl.Listener(*wlr.Seat.event.RequestSetSelection).init(handleRequestSetSelection),
request_start_drag: wl.Listener(*wlr.Seat.event.RequestStartDrag) =
    wl.Listener(*wlr.Seat.event.RequestStartDrag).init(handleRequestStartDrag),
start_drag: wl.Listener(*wlr.Drag) = wl.Listener(*wlr.Drag).init(handleStartDrag),
pointer_drag_destroy: wl.Listener(*wlr.Drag) = wl.Listener(*wlr.Drag).init(handlePointerDragDestroy),
request_set_primary_selection: wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection) =
    wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection).init(handleRequestSetPrimarySelection),

pub fn init(self: *Self, name: [*:0]const u8) !void {
    const event_loop = server.wl_server.getEventLoop();
    const mapping_repeat_timer = try event_loop.addTimer(*Self, handleMappingRepeatTimeout, self);
    errdefer mapping_repeat_timer.remove();

    self.* = .{
        // This will be automatically destroyed when the display is destroyed
        .wlr_seat = try wlr.Seat.create(server.wl_server, name),
        .focused_output = &server.root.noop_output,
        .mapping_repeat_timer = mapping_repeat_timer,
    };
    self.wlr_seat.data = @ptrToInt(self);

    try self.cursor.init(self);

    self.wlr_seat.events.request_set_selection.add(&self.request_set_selection);
    self.wlr_seat.events.request_start_drag.add(&self.request_start_drag);
    self.wlr_seat.events.start_drag.add(&self.start_drag);
    self.wlr_seat.events.request_set_primary_selection.add(&self.request_set_primary_selection);
}

pub fn deinit(self: *Self) void {
    {
        var it = server.input_manager.devices.iterator(.forward);
        while (it.next()) |device| assert(device.seat != self);
    }

    self.cursor.deinit();
    self.mapping_repeat_timer.remove();

    while (self.focus_stack.first) |node| {
        self.focus_stack.remove(node);
        util.gpa.destroy(node);
    }

    self.request_set_selection.link.remove();
    self.request_start_drag.link.remove();
    self.start_drag.link.remove();
    if (self.pointer_drag) self.pointer_drag_destroy.link.remove();
    self.request_set_primary_selection.link.remove();
}

/// Set the current focus. If a visible view is passed it will be focused.
/// If null is passed, the first visible view in the focus stack will be focused.
pub fn focus(self: *Self, _target: ?*View) void {
    var target = _target;

    // While a layer surface is focused, views may not recieve focus
    if (self.focused == .layer) return;

    if (target) |view| {
        // If the view is not currently visible, behave as if null was passed
        if (view.pending.tags & view.output.pending.tags == 0) {
            target = null;
        } else {
            // If the view is not on the currently focused output, focus it
            if (view.output != self.focused_output) self.focusOutput(view.output);
        }
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

    // Focus the target view or clear the focus if target is null
    if (target) |view| {
        // Find the node for this view in the focus stack and move it to the top.
        var it = self.focus_stack.first;
        while (it) |node| : (it = node.next) {
            if (node.view == view) {
                self.focus_stack.remove(node);
                self.focus_stack.push(node);
                break;
            }
        } else {
            // A node is added when new Views are mapped in Seat.handleViewMap()
            unreachable;
        }
        self.setFocusRaw(.{ .view = view });
    } else {
        self.setFocusRaw(.{ .none = {} });
    }
}

fn pendingFilter(view: *View, filter_tags: u32) bool {
    return view.surface != null and view.pending.tags & filter_tags != 0;
}

/// Switch focus to the target, handling unfocus and input inhibition
/// properly. This should only be called directly if dealing with layers or
/// override redirect xwayland views.
pub fn setFocusRaw(self: *Self, new_focus: FocusTarget) void {
    // If the target is already focused, do nothing
    if (std.meta.eql(new_focus, self.focused)) return;

    // Obtain the target surface
    const target_surface = switch (new_focus) {
        .view => |target_view| target_view.surface.?,
        .xwayland_override_redirect => |target_override_redirect| blk: {
            assert(build_options.xwayland);
            break :blk target_override_redirect.xwayland_surface.surface;
        },
        .layer => |target_layer| target_layer.wlr_layer_surface.surface,
        .none => null,
    };

    // If input is not allowed on the target surface (e.g. due to an active
    // input inhibitor) do not set focus. If there is no target surface we
    // still clear the focus.
    if (if (target_surface) |wlr_surface| server.input_manager.inputAllowed(wlr_surface) else true) {
        // First clear the current focus
        switch (self.focused) {
            .view => |view| {
                view.pending.focus -= 1;
                if (view.pending.focus == 0) view.setActivated(false);
            },
            .xwayland_override_redirect, .layer, .none => {},
        }

        // Set the new focus
        switch (new_focus) {
            .view => |target_view| {
                assert(self.focused_output == target_view.output);
                if (target_view.pending.focus == 0) target_view.setActivated(true);
                target_view.pending.focus += 1;
                target_view.pending.urgent = false;
            },
            .layer => |target_layer| assert(self.focused_output == target_layer.output),
            .xwayland_override_redirect, .none => {},
        }
        self.focused = new_focus;

        // Send keyboard enter/leave events and handle pointer constraints
        if (target_surface) |wlr_surface| {
            self.keyboardNotifyEnter(wlr_surface);

            if (server.input_manager.pointer_constraints.constraintForSurface(wlr_surface, self.wlr_seat)) |constraint| {
                @intToPtr(*PointerConstraint, constraint.data).setAsActive();
            } else if (self.cursor.constraint) |constraint| {
                PointerConstraint.warpToHint(&self.cursor);
                constraint.sendDeactivated();
                self.cursor.constraint = null;
            }
        } else {
            self.wlr_seat.keyboardClearFocus();

            if (self.cursor.constraint) |constraint| {
                PointerConstraint.warpToHint(&self.cursor);
                constraint.sendDeactivated();
                self.cursor.constraint = null;
            }
        }
    }

    // Inform any clients tracking status of the change
    var it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendFocusedView();
}

fn keyboardNotifyEnter(self: *Self, wlr_surface: *wlr.Surface) void {
    if (self.wlr_seat.getKeyboard()) |wlr_keyboard| {
        var keycodes = KeycodeSet{
            .items = wlr_keyboard.keycodes,
            .len = wlr_keyboard.num_keycodes,
        };

        const keyboard = @intToPtr(*Keyboard, wlr_keyboard.data);
        keycodes.subtract(keyboard.eaten_keycodes);

        self.wlr_seat.keyboardNotifyEnter(
            wlr_surface,
            &keycodes.items,
            keycodes.len,
            &wlr_keyboard.modifiers,
        );
    } else {
        self.wlr_seat.keyboardNotifyEnter(wlr_surface, null, 0, null);
    }
}

/// Focus the given output, notifying any listening clients of the change.
pub fn focusOutput(self: *Self, output: *Output) void {
    if (self.focused_output == output) return;

    var it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendOutput(.unfocused);

    self.focused_output = output;

    it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendOutput(.focused);

    if (self.focused_output == &server.root.noop_output) return;

    // Warp pointer to center of newly focused output (In layout coordinates),
    // but only if cursor is not already on the output and this feature is enabled.
    switch (server.config.warp_cursor) {
        .disabled => {},
        .@"on-output-change" => {
            const layout_box = server.root.output_layout.getBox(output.wlr_output).?;
            if (!layout_box.containsPoint(self.cursor.wlr_cursor.x, self.cursor.wlr_cursor.y)) {
                const eff_res = output.getEffectiveResolution();
                const lx = @intToFloat(f32, layout_box.x + @intCast(i32, eff_res.width / 2));
                const ly = @intToFloat(f32, layout_box.y + @intCast(i32, eff_res.height / 2));
                if (!self.cursor.wlr_cursor.warp(null, lx, ly)) {
                    log.err("failed to warp cursor on output change", .{});
                }
            }
        },
    }
}

pub fn handleActivity(self: Self) void {
    server.input_manager.idle.notifyActivity(self.wlr_seat);
}

pub fn handleViewMap(self: *Self, view: *View) !void {
    const new_focus_node = try util.gpa.create(ViewStack(*View).Node);
    new_focus_node.view = view;
    self.focus_stack.append(new_focus_node);
    self.focus(view);
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

pub fn enterMode(self: *Self, mode_id: u32) void {
    self.mode_id = mode_id;

    var it = self.status_trackers.first;
    while (it) |node| : (it = node.next) {
        node.data.sendMode(server.config.modes.items[mode_id].name);
    }
}

/// Is there a user-defined mapping for passed keycode, modifiers and keyboard state?
pub fn hasMapping(
    self: *Self,
    keycode: xkb.Keycode,
    modifiers: wlr.Keyboard.ModifierMask,
    released: bool,
    xkb_state: *xkb.State,
) bool {
    const modes = &server.config.modes;
    for (modes.items[self.mode_id].mappings.items) |*mapping| {
        if (mapping.match(keycode, modifiers, released, xkb_state)) {
            return true;
        }
    }
    return false;
}

/// Handle any user-defined mapping for passed keycode, modifiers and keyboard state
/// Returns true if at least one mapping was run
pub fn handleMapping(
    self: *Self,
    keycode: xkb.Keycode,
    modifiers: wlr.Keyboard.ModifierMask,
    released: bool,
    xkb_state: *xkb.State,
) bool {
    const modes = &server.config.modes;
    // In case more than one mapping matches, all of them are activated
    var handled = false;
    for (modes.items[self.mode_id].mappings.items) |*mapping| {
        if (mapping.match(keycode, modifiers, released, xkb_state)) {
            if (mapping.repeat) {
                self.repeating_mapping = mapping;
                self.mapping_repeat_timer.timerUpdate(server.config.repeat_delay) catch {
                    log.err("failed to update mapping repeat timer", .{});
                };
            }
            self.runCommand(mapping.command_args);
            handled = true;
        }
    }
    return handled;
}

/// Handle any user-defined mapping for passed button, modifiers and keyboard state.
/// Returns true if there was a mapping.
pub fn handleButtonMapping(
    self: *Self,
    event_code: u32,
    modifiers: wlr.Keyboard.ModifierMask,
) bool {
    const modes = &server.config.modes;
    for (modes.items[self.mode_id].button_mappings.items) |*mapping| {
        if (mapping.match(event_code, modifiers)) {
            self.runCommand(mapping.command_args);
            return true;
        }
    }
    return false;
}

/// Handle any user-defined mapping for switches
pub fn handleSwitchMapping(
    self: *Self,
    switch_type: Switch.Type,
    switch_state: Switch.State,
) void {
    const modes = &server.config.modes;
    for (modes.items[self.mode_id].switch_mappings.items) |mapping| {
        if (std.meta.eql(mapping.switch_type, switch_type) and std.meta.eql(mapping.switch_state, switch_state)) {
            self.runCommand(mapping.command_args);
        }
    }
}

fn runCommand(self: *Self, args: []const [:0]const u8) void {
    var out: ?[]const u8 = null;
    defer if (out) |s| util.gpa.free(s);
    command.run(self, args, &out) catch |err| {
        const failure_message = switch (err) {
            command.Error.Other => out.?,
            else => command.errToMsg(err),
        };
        std.log.scoped(.command).err("{s}: {s}", .{ args[0], failure_message });
        return;
    };
    if (out) |s| {
        const stdout = std.io.getStdOut().writer();
        stdout.print("{s}", .{s}) catch |err| {
            std.log.scoped(.command).err("{s}: write to stdout failed {}", .{ args[0], err });
        };
    }
}

pub fn clearRepeatingMapping(self: *Self) void {
    self.mapping_repeat_timer.timerUpdate(0) catch {
        log.err("failed to clear mapping repeat timer", .{});
    };
    self.repeating_mapping = null;
}

/// Repeat key mapping
fn handleMappingRepeatTimeout(self: *Self) callconv(.C) c_int {
    if (self.repeating_mapping) |mapping| {
        const rate = server.config.repeat_rate;
        const ms_delay = if (rate > 0) 1000 / rate else 0;
        self.mapping_repeat_timer.timerUpdate(ms_delay) catch {
            log.err("failed to update mapping repeat timer", .{});
        };
        self.runCommand(mapping.command_args);
    }
    return 0;
}

pub fn addDevice(self: *Self, wlr_device: *wlr.InputDevice) void {
    self.tryAddDevice(wlr_device) catch |err| switch (err) {
        error.OutOfMemory => log.err("out of memory", .{}),
        error.XkbContextFailed => log.err("failed to create xkbcommon context", .{}),
        error.XkbKeymapFailed => log.err("failed to create xkbcommon keymap", .{}),
        error.SetKeymapFailed => log.err("failed to set wlroots keymap", .{}),
    };
}

fn tryAddDevice(self: *Self, wlr_device: *wlr.InputDevice) !void {
    switch (wlr_device.type) {
        .keyboard => {
            const keyboard = try util.gpa.create(Keyboard);
            errdefer util.gpa.destroy(keyboard);

            try keyboard.init(self, wlr_device);

            self.wlr_seat.setKeyboard(keyboard.device.wlr_device);
            if (self.wlr_seat.keyboard_state.focused_surface) |wlr_surface| {
                self.wlr_seat.keyboardNotifyClearFocus();
                self.keyboardNotifyEnter(wlr_surface);
            }
        },
        .pointer, .touch => {
            const device = try util.gpa.create(InputDevice);
            errdefer util.gpa.destroy(device);

            try device.init(self, wlr_device);

            self.cursor.wlr_cursor.attachInputDevice(wlr_device);
        },
        .switch_device => {
            const switch_device = try util.gpa.create(Switch);
            errdefer util.gpa.destroy(switch_device);

            try switch_device.init(self, wlr_device);
        },

        // TODO Support these types of input devices.
        .tablet_tool, .tablet_pad => return,
    }
}

pub fn updateCapabilities(self: *Self) void {
    // Currently a cursor is always drawn even if there are no pointer input devices.
    // TODO Don't draw a cursor if there are no input devices.
    var capabilities: wl.Seat.Capability = .{ .pointer = true };

    var it = server.input_manager.devices.iterator(.forward);
    while (it.next()) |device| {
        if (device.seat == self) {
            switch (device.wlr_device.type) {
                .keyboard => capabilities.keyboard = true,
                .touch => capabilities.touch = true,
                .pointer, .switch_device => {},
                .tablet_tool, .tablet_pad => unreachable,
            }
        }
    }

    self.wlr_seat.setCapabilities(capabilities);
}

fn handleRequestSetSelection(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
    event: *wlr.Seat.event.RequestSetSelection,
) void {
    const self = @fieldParentPtr(Self, "request_set_selection", listener);
    self.wlr_seat.setSelection(event.source, event.serial);
}

fn handleRequestStartDrag(
    listener: *wl.Listener(*wlr.Seat.event.RequestStartDrag),
    event: *wlr.Seat.event.RequestStartDrag,
) void {
    const self = @fieldParentPtr(Self, "request_start_drag", listener);

    if (!self.wlr_seat.validatePointerGrabSerial(event.origin, event.serial)) {
        log.debug("ignoring request to start drag, " ++
            "failed to validate pointer serial {}", .{event.serial});
        if (event.drag.source) |source| source.destroy();
        return;
    }

    if (self.pointer_drag) {
        log.debug("ignoring request to start pointer drag, " ++
            "another pointer drag is already in progress", .{});
        return;
    }

    log.debug("starting pointer drag", .{});
    self.wlr_seat.startPointerDrag(event.drag, event.serial);
}

fn handleStartDrag(listener: *wl.Listener(*wlr.Drag), wlr_drag: *wlr.Drag) void {
    const self = @fieldParentPtr(Self, "start_drag", listener);

    assert(wlr_drag.grab_type == .keyboard_pointer);

    self.pointer_drag = true;
    wlr_drag.events.destroy.add(&self.pointer_drag_destroy);

    if (wlr_drag.icon) |wlr_drag_icon| {
        const node = util.gpa.create(std.SinglyLinkedList(DragIcon).Node) catch {
            log.err("out of memory", .{});
            wlr_drag.seat_client.client.postNoMemory();
            return;
        };
        node.data.init(self, wlr_drag_icon);
        server.root.drag_icons.prepend(node);
    }
    self.cursor.mode = .passthrough;
}

fn handlePointerDragDestroy(listener: *wl.Listener(*wlr.Drag), _: *wlr.Drag) void {
    const self = @fieldParentPtr(Self, "pointer_drag_destroy", listener);
    self.pointer_drag_destroy.link.remove();

    self.pointer_drag = false;
    self.cursor.checkFocusFollowsCursor();
    self.cursor.updateState();
}

fn handleRequestSetPrimarySelection(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection),
    event: *wlr.Seat.event.RequestSetPrimarySelection,
) void {
    const self = @fieldParentPtr(Self, "request_set_primary_selection", listener);
    self.wlr_seat.setPrimarySelection(event.source, event.serial);
}
