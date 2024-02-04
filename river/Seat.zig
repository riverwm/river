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
const InputRelay = @import("InputRelay.zig");
const Keyboard = @import("Keyboard.zig");
const KeyboardGroup = @import("KeyboardGroup.zig");
const KeycodeSet = @import("KeycodeSet.zig");
const LayerSurface = @import("LayerSurface.zig");
const LockSurface = @import("LockSurface.zig");
const Mapping = @import("Mapping.zig");
const Output = @import("Output.zig");
const PointerConstraint = @import("PointerConstraint.zig");
const SeatStatus = @import("SeatStatus.zig");
const Switch = @import("Switch.zig");
const View = @import("View.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");

const log = std.log.scoped(.seat);

pub const FocusTarget = union(enum) {
    view: *View,
    xwayland_override_redirect: if (build_options.xwayland) *XwaylandOverrideRedirect else noreturn,
    layer: *LayerSurface,
    lock_surface: *LockSurface,
    none: void,

    pub fn surface(target: FocusTarget) ?*wlr.Surface {
        return switch (target) {
            .view => |view| view.rootSurface(),
            .xwayland_override_redirect => |xwayland_or| xwayland_or.xwayland_surface.surface,
            .layer => |layer| layer.wlr_layer_surface.surface,
            .lock_surface => |lock_surface| lock_surface.wlr_lock_surface.surface,
            .none => null,
        };
    }
};

wlr_seat: *wlr.Seat,

/// Multiple mice are handled by the same Cursor
cursor: Cursor,
/// Input Method handling
relay: InputRelay,

/// ID of the current keymap mode
mode_id: u32 = 0,

/// ID of previous keymap mode, used when returning from "locked" mode
prev_mode_id: u32 = 0,

/// Timer for repeating keyboard mappings
mapping_repeat_timer: *wl.EventSource,

/// Currently repeating mapping, if any
repeating_mapping: ?*const Mapping = null,

keyboard_groups: std.TailQueue(KeyboardGroup) = .{},

/// Currently focused output. Null only when there are no outputs at all.
focused_output: ?*Output = null,

focused: FocusTarget = .none,

/// List of status tracking objects relaying changes to this seat to clients.
status_trackers: std.SinglyLinkedList(SeatStatus) = .{},

/// The currently in progress drag operation type.
drag: enum {
    none,
    pointer,
    touch,
} = .none,

request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) =
    wl.Listener(*wlr.Seat.event.RequestSetSelection).init(handleRequestSetSelection),
request_start_drag: wl.Listener(*wlr.Seat.event.RequestStartDrag) =
    wl.Listener(*wlr.Seat.event.RequestStartDrag).init(handleRequestStartDrag),
start_drag: wl.Listener(*wlr.Drag) = wl.Listener(*wlr.Drag).init(handleStartDrag),
drag_destroy: wl.Listener(*wlr.Drag) = wl.Listener(*wlr.Drag).init(handleDragDestroy),
request_set_primary_selection: wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection) =
    wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection).init(handleRequestSetPrimarySelection),

pub fn init(self: *Self, name: [*:0]const u8) !void {
    const event_loop = server.wl_server.getEventLoop();
    const mapping_repeat_timer = try event_loop.addTimer(*Self, handleMappingRepeatTimeout, self);
    errdefer mapping_repeat_timer.remove();

    self.* = .{
        // This will be automatically destroyed when the display is destroyed
        .wlr_seat = try wlr.Seat.create(server.wl_server, name),
        .cursor = undefined,
        .relay = undefined,
        .mapping_repeat_timer = mapping_repeat_timer,
    };
    self.wlr_seat.data = @intFromPtr(self);

    try self.cursor.init(self);
    self.relay.init();

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

    while (self.keyboard_groups.first) |node| {
        node.data.destroy();
    }

    self.request_set_selection.link.remove();
    self.request_start_drag.link.remove();
    self.start_drag.link.remove();
    if (self.drag != .none) self.drag_destroy.link.remove();
    self.request_set_primary_selection.link.remove();
}

/// Set the current focus. If a visible view is passed it will be focused.
/// If null is passed, the top view in the stack of the focused output will be focused.
/// Requires a call to Root.applyPending()
pub fn focus(self: *Self, _target: ?*View) void {
    var target = _target;

    // Don't change focus if there are no outputs.
    if (self.focused_output == null) return;

    // Views may not receive focus while locked.
    if (server.lock_manager.state != .unlocked) return;

    // While a layer surface is exclusively focused, views may not receive focus
    if (self.focused == .layer) {
        const wlr_layer_surface = self.focused.layer.wlr_layer_surface;
        assert(wlr_layer_surface.surface.mapped);
        if (wlr_layer_surface.current.keyboard_interactive == .exclusive and
            (wlr_layer_surface.current.layer == .top or wlr_layer_surface.current.layer == .overlay))
        {
            return;
        }
    }

    if (target) |view| {
        if (view.pending.output == null or
            view.pending.tags & view.pending.output.?.pending.tags == 0)
        {
            // If the view is not currently visible, behave as if null was passed
            target = null;
        } else if (view.pending.output.? != self.focused_output.?) {
            // If the view is not on the currently focused output, focus it
            self.focusOutput(view.pending.output.?);
        }
    }

    {
        var it = self.focused_output.?.pending.focus_stack.iterator(.forward);
        while (it.next()) |view| {
            if (view.pending.fullscreen and
                view.pending.tags & self.focused_output.?.pending.tags != 0)
            {
                target = view;
                break;
            }
        }
    }

    // If null, set the target to the first currently visible view in the focus stack if any
    if (target == null) {
        var it = self.focused_output.?.pending.focus_stack.iterator(.forward);
        target = while (it.next()) |view| {
            if (view.pending.tags & self.focused_output.?.pending.tags != 0) {
                break view;
            }
        } else null;
    }

    // Focus the target view or clear the focus if target is null
    if (target) |view| {
        view.pending_focus_stack_link.remove();
        self.focused_output.?.pending.focus_stack.prepend(view);
        self.setFocusRaw(.{ .view = view });
    } else {
        self.setFocusRaw(.{ .none = {} });
    }
}

/// Switch focus to the target, handling unfocus and input inhibition
/// properly. This should only be called directly if dealing with layers or
/// override redirect xwayland views.
pub fn setFocusRaw(self: *Self, new_focus: FocusTarget) void {
    // If the target is already focused, do nothing
    if (std.meta.eql(new_focus, self.focused)) return;

    const target_surface = new_focus.surface();

    // First clear the current focus
    switch (self.focused) {
        .view => |view| {
            view.pending.focus -= 1;
            view.destroyPopups();
        },
        .layer => |layer_surface| {
            layer_surface.destroyPopups();
        },
        .xwayland_override_redirect, .lock_surface, .none => {},
    }

    // Set the new focus
    switch (new_focus) {
        .view => |target_view| {
            assert(server.lock_manager.state != .locked);
            assert(self.focused_output == target_view.pending.output);
            target_view.pending.focus += 1;
            target_view.pending.urgent = false;
        },
        .layer => |target_layer| {
            assert(server.lock_manager.state != .locked);
            assert(self.focused_output == target_layer.output);
        },
        .lock_surface => assert(server.lock_manager.state != .unlocked),
        .xwayland_override_redirect, .none => {},
    }
    self.focused = new_focus;

    if (self.cursor.constraint) |constraint| {
        if (constraint.wlr_constraint.surface != target_surface) {
            if (constraint.state == .active) {
                log.info("deactivating pointer constraint for surface, keyboard focus lost", .{});
                constraint.deactivate();
            }
            self.cursor.constraint = null;
        }
    }

    self.keyboardEnterOrLeave(target_surface);
    self.relay.focus(target_surface);

    if (target_surface) |surface| {
        const pointer_constraints = server.input_manager.pointer_constraints;
        if (pointer_constraints.constraintForSurface(surface, self.wlr_seat)) |wlr_constraint| {
            if (self.cursor.constraint) |constraint| {
                assert(constraint.wlr_constraint == wlr_constraint);
            } else {
                self.cursor.constraint = @ptrFromInt(wlr_constraint.data);
                assert(self.cursor.constraint != null);
            }
        }
    }

    // Depending on configuration and cursor position, changing keyboard focus
    // may cause the cursor to be warped.
    self.cursor.may_need_warp = true;

    // Inform any clients tracking status of the change
    var it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendFocusedView();
}

/// Send keyboard enter/leave events and handle pointer constraints
/// This should never normally be called from outside of setFocusRaw(), but we make an exception for
/// XwaylandOverrideRedirect surfaces as they don't conform to the Wayland focus model.
pub fn keyboardEnterOrLeave(self: *Self, target_surface: ?*wlr.Surface) void {
    if (target_surface) |wlr_surface| {
        self.keyboardNotifyEnter(wlr_surface);
    } else {
        self.wlr_seat.keyboardNotifyClearFocus();
    }
}

fn keyboardNotifyEnter(self: *Self, wlr_surface: *wlr.Surface) void {
    if (self.wlr_seat.getKeyboard()) |wlr_keyboard| {
        var keycodes = KeycodeSet{
            .items = wlr_keyboard.keycodes,
            .reason = .{.none} ** 32,
            .len = wlr_keyboard.num_keycodes,
        };

        const keyboard: *Keyboard = @ptrFromInt(wlr_keyboard.data);
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
pub fn focusOutput(self: *Self, output: ?*Output) void {
    if (self.focused_output == output) return;

    if (self.focused_output) |old| {
        var it = self.status_trackers.first;
        while (it) |node| : (it = node.next) node.data.sendOutput(old, .unfocused);
    }

    self.focused_output = output;

    if (self.focused_output) |new| {
        var it = self.status_trackers.first;
        while (it) |node| : (it = node.next) node.data.sendOutput(new, .focused);
    }

    // Depending on configuration and cursor position, changing output focus
    // may cause the cursor to be warped.
    self.cursor.may_need_warp = true;
}

pub fn handleActivity(self: Self) void {
    server.input_manager.idle_notifier.notifyActivity(self.wlr_seat);
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
        if (mapping.match(keycode, modifiers, released, xkb_state, .no_translate) or
            mapping.match(keycode, modifiers, released, xkb_state, .translate))
        {
            return true;
        }
    }
    return false;
}

/// Handle any user-defined mapping for passed keycode, modifiers and keyboard state
/// Returns true if a mapping was run
pub fn handleMapping(
    self: *Self,
    keycode: xkb.Keycode,
    modifiers: wlr.Keyboard.ModifierMask,
    released: bool,
    xkb_state: *xkb.State,
) bool {
    const modes = &server.config.modes;

    // It is possible for more than one mapping to be matched due to the
    // existence of layout-independent mappings. It is also possible due to
    // translation by xkbcommon consuming modifiers. On the swedish layout
    // for example, translating Super+Shift+Space may consume the Shift
    // modifier and confict with a mapping for Super+Space. For this reason,
    // matching wihout xkbcommon translation is done first and after a match
    // has been found all further matches are ignored.
    var found: ?*Mapping = null;

    // First check for matches without translating keysyms with xkbcommon.
    // That is, if the physical keys Mod+Shift+1 are pressed on a US layout don't
    // translate the keysym 1 to an exclamation mark. This behavior is generally
    // what is desired.
    for (modes.items[self.mode_id].mappings.items) |*mapping| {
        if (mapping.match(keycode, modifiers, released, xkb_state, .no_translate)) {
            if (found == null) {
                found = mapping;
            } else {
                log.debug("already found a matching mapping, ignoring additional match", .{});
            }
        }
    }

    // There are however some cases where it is necessary to translate keysyms
    // with xkbcommon for intuitive behavior. For example, layouts may require
    // translation with the numlock modifier to obtain keypad number keysyms
    // (e.g. KP_1).
    for (modes.items[self.mode_id].mappings.items) |*mapping| {
        if (mapping.match(keycode, modifiers, released, xkb_state, .translate)) {
            if (found == null) {
                found = mapping;
            } else {
                log.debug("already found a matching mapping, ignoring additional match", .{});
            }
        }
    }

    // The mapped command must be run outside of the loop above as it may modify
    // the list of mappings we are iterating through, possibly causing it to be re-allocated.
    if (found) |mapping| {
        if (mapping.options.repeat) {
            self.repeating_mapping = mapping;
            self.mapping_repeat_timer.timerUpdate(server.config.repeat_delay) catch {
                log.err("failed to update mapping repeat timer", .{});
            };
        }
        self.runCommand(mapping.command_args);
        return true;
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

pub fn runCommand(self: *Self, args: []const [:0]const u8) void {
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
fn handleMappingRepeatTimeout(self: *Self) c_int {
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
    };
}

fn tryAddDevice(self: *Self, wlr_device: *wlr.InputDevice) !void {
    switch (wlr_device.type) {
        .keyboard => {
            const keyboard = try util.gpa.create(Keyboard);
            errdefer util.gpa.destroy(keyboard);

            try keyboard.init(self, wlr_device);

            self.wlr_seat.setKeyboard(keyboard.device.wlr_device.toKeyboard());
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

    // The start_drag request is ignored by wlroots if a drag is currently in progress.
    assert(self.drag == .none);

    if (self.wlr_seat.validatePointerGrabSerial(event.origin, event.serial)) {
        log.debug("starting pointer drag", .{});
        self.wlr_seat.startPointerDrag(event.drag, event.serial);
        return;
    }

    var point: *wlr.TouchPoint = undefined;
    if (self.wlr_seat.validateTouchGrabSerial(event.origin, event.serial, &point)) {
        log.debug("starting touch drag", .{});
        self.wlr_seat.startTouchDrag(event.drag, event.serial, point);
        return;
    }

    log.debug("ignoring request to start drag, " ++
        "failed to validate pointer or touch serial {}", .{event.serial});
    if (event.drag.source) |source| source.destroy();
}

fn handleStartDrag(listener: *wl.Listener(*wlr.Drag), wlr_drag: *wlr.Drag) void {
    const self = @fieldParentPtr(Self, "start_drag", listener);

    assert(self.drag == .none);
    switch (wlr_drag.grab_type) {
        .keyboard_pointer => {
            self.drag = .pointer;
            self.cursor.mode = .passthrough;
        },
        .keyboard_touch => self.drag = .touch,
        .keyboard => unreachable,
    }
    wlr_drag.events.destroy.add(&self.drag_destroy);

    if (wlr_drag.icon) |wlr_drag_icon| {
        DragIcon.create(wlr_drag_icon, &self.cursor) catch {
            log.err("out of memory", .{});
            wlr_drag.seat_client.client.postNoMemory();
            return;
        };
    }
}

fn handleDragDestroy(listener: *wl.Listener(*wlr.Drag), _: *wlr.Drag) void {
    const self = @fieldParentPtr(Self, "drag_destroy", listener);
    self.drag_destroy.link.remove();

    switch (self.drag) {
        .none => unreachable,
        .pointer => {
            self.cursor.checkFocusFollowsCursor();
            self.cursor.updateState();
        },
        .touch => {},
    }
    self.drag = .none;
}

fn handleRequestSetPrimarySelection(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection),
    event: *wlr.Seat.event.RequestSetPrimarySelection,
) void {
    const self = @fieldParentPtr(Self, "request_set_primary_selection", listener);
    self.wlr_seat.setPrimarySelection(event.source, event.serial);
}
