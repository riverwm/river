// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 - 2021 The River Developers
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

const InputManager = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const InputDevice = @import("InputDevice.zig");
const InputRelay = @import("InputRelay.zig");
const Keyboard = @import("Keyboard.zig");
const PointerConstraint = @import("PointerConstraint.zig");
const Seat = @import("Seat.zig");
const TextInput = @import("TextInput.zig");

const default_seat_name = "default";

const log = std.log.scoped(.input);

new_input: wl.Listener(*wlr.InputDevice) = .init(handleNewInput),

idle_notifier: *wlr.IdleNotifierV1,
relative_pointer_manager: *wlr.RelativePointerManagerV1,
pointer_gestures: *wlr.PointerGesturesV1,
virtual_pointer_manager: *wlr.VirtualPointerManagerV1,
virtual_keyboard_manager: *wlr.VirtualKeyboardManagerV1,
pointer_constraints: *wlr.PointerConstraintsV1,
input_method_manager: *wlr.InputMethodManagerV2,
text_input_manager: *wlr.TextInputManagerV3,
tablet_manager: *wlr.TabletManagerV2,

devices: wl.list.Head(InputDevice, .link),
seats: wl.list.Head(Seat, .link),

new_virtual_pointer: wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer) = .init(handleNewVirtualPointer),
new_virtual_keyboard: wl.Listener(*wlr.VirtualKeyboardV1) = .init(handleNewVirtualKeyboard),
new_constraint: wl.Listener(*wlr.PointerConstraintV1) = .init(handleNewConstraint),
new_input_method: wl.Listener(*wlr.InputMethodV2) = .init(handleNewInputMethod),
new_text_input: wl.Listener(*wlr.TextInputV3) = .init(handleNewTextInput),

pub fn init(input_manager: *InputManager) !void {
    input_manager.* = .{
        // These are automatically freed when the display is destroyed
        .idle_notifier = try wlr.IdleNotifierV1.create(server.wl_server),
        .relative_pointer_manager = try wlr.RelativePointerManagerV1.create(server.wl_server),
        .pointer_gestures = try wlr.PointerGesturesV1.create(server.wl_server),
        .virtual_pointer_manager = try wlr.VirtualPointerManagerV1.create(server.wl_server),
        .virtual_keyboard_manager = try wlr.VirtualKeyboardManagerV1.create(server.wl_server),
        .pointer_constraints = try wlr.PointerConstraintsV1.create(server.wl_server),
        .input_method_manager = try wlr.InputMethodManagerV2.create(server.wl_server),
        .text_input_manager = try wlr.TextInputManagerV3.create(server.wl_server),
        .tablet_manager = try wlr.TabletManagerV2.create(server.wl_server),

        .devices = undefined,
        .seats = undefined,
    };
    input_manager.devices.init();
    input_manager.seats.init();

    try Seat.create(default_seat_name);

    if (build_options.xwayland) {
        if (server.xwayland) |xwayland| {
            xwayland.setSeat(input_manager.defaultSeat().wlr_seat);
        }
    }

    server.backend.events.new_input.add(&input_manager.new_input);
    input_manager.virtual_pointer_manager.events.new_virtual_pointer.add(&input_manager.new_virtual_pointer);
    input_manager.virtual_keyboard_manager.events.new_virtual_keyboard.add(&input_manager.new_virtual_keyboard);
    input_manager.pointer_constraints.events.new_constraint.add(&input_manager.new_constraint);
    input_manager.input_method_manager.events.input_method.add(&input_manager.new_input_method);
    input_manager.text_input_manager.events.text_input.add(&input_manager.new_text_input);
}

pub fn deinit(input_manager: *InputManager) void {
    // This function must be called after the backend has been destroyed
    assert(input_manager.devices.empty());

    input_manager.new_virtual_pointer.link.remove();
    input_manager.new_virtual_keyboard.link.remove();
    input_manager.new_constraint.link.remove();
    input_manager.new_input_method.link.remove();
    input_manager.new_text_input.link.remove();

    while (input_manager.seats.first()) |seat| {
        seat.destroy();
    }
}

pub fn defaultSeat(input_manager: *InputManager) *Seat {
    return input_manager.seats.first().?;
}

pub fn processEvents(input_manager: *InputManager) void {
    assert(server.wm.state == .idle);

    var it = input_manager.seats.iterator(.forward);
    while (it.next()) |seat| {
        seat.processEvents();
    }
}

/// Reconfigures all devices' libinput configuration as well as their output mapping.
/// This is called on outputs being added or removed and on the input configuration being changed.
pub fn reconfigureDevices(input_manager: *InputManager) void {
    var it = input_manager.devices.iterator(.forward);
    while (it.next()) |device| {
        _ = device;
    }
}

fn handleNewInput(listener: *wl.Listener(*wlr.InputDevice), wlr_device: *wlr.InputDevice) void {
    const input_manager: *InputManager = @fieldParentPtr("new_input", listener);

    input_manager.defaultSeat().addDevice(wlr_device, false);
}

fn handleNewVirtualPointer(
    listener: *wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer),
    event: *wlr.VirtualPointerManagerV1.event.NewPointer,
) void {
    const input_manager: *InputManager = @fieldParentPtr("new_virtual_pointer", listener);

    // TODO Support multiple seats and don't ignore
    if (event.suggested_seat != null) {
        log.debug("Ignoring seat suggestion from virtual pointer", .{});
    }
    // TODO dont ignore output suggestion
    if (event.suggested_output != null) {
        log.debug("Ignoring output suggestion from virtual pointer", .{});
    }

    input_manager.defaultSeat().addDevice(&event.new_pointer.pointer.base, true);
}

fn handleNewVirtualKeyboard(
    _: *wl.Listener(*wlr.VirtualKeyboardV1),
    virtual_keyboard: *wlr.VirtualKeyboardV1,
) void {
    const no_keymap = util.gpa.create(NoKeymapVirtKeyboard) catch {
        log.err("out of memory", .{});
        return;
    };
    errdefer util.gpa.destroy(no_keymap);

    no_keymap.* = .{
        .virtual_keyboard = virtual_keyboard,
    };
    virtual_keyboard.keyboard.base.events.destroy.add(&no_keymap.destroy);
    virtual_keyboard.keyboard.events.keymap.add(&no_keymap.keymap);
}

/// Ignore virtual keyboards completely until the client sets a keymap
/// Yes, wlroots should probably do this for us.
const NoKeymapVirtKeyboard = struct {
    virtual_keyboard: *wlr.VirtualKeyboardV1,
    destroy: wl.Listener(*wlr.InputDevice) = .init(handleDestroy),
    keymap: wl.Listener(*wlr.Keyboard) = .init(handleKeymap),

    fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
        const no_keymap: *NoKeymapVirtKeyboard = @fieldParentPtr("destroy", listener);

        no_keymap.destroy.link.remove();
        no_keymap.keymap.link.remove();

        util.gpa.destroy(no_keymap);
    }

    fn handleKeymap(listener: *wl.Listener(*wlr.Keyboard), _: *wlr.Keyboard) void {
        const no_keymap: *NoKeymapVirtKeyboard = @fieldParentPtr("keymap", listener);
        const virtual_keyboard = no_keymap.virtual_keyboard;

        handleDestroy(&no_keymap.destroy, &virtual_keyboard.keyboard.base);

        const seat: *Seat = @ptrCast(@alignCast(virtual_keyboard.seat.data));
        seat.addDevice(&virtual_keyboard.keyboard.base, true);
    }
};

fn handleNewConstraint(
    _: *wl.Listener(*wlr.PointerConstraintV1),
    wlr_constraint: *wlr.PointerConstraintV1,
) void {
    PointerConstraint.create(wlr_constraint) catch {
        log.err("out of memory", .{});
        wlr_constraint.resource.postNoMemory();
    };
}

fn handleNewInputMethod(_: *wl.Listener(*wlr.InputMethodV2), input_method: *wlr.InputMethodV2) void {
    const seat: *Seat = @ptrCast(@alignCast(input_method.seat.data));

    log.debug("new input method on seat {s}", .{seat.wlr_seat.name});

    seat.relay.newInputMethod(input_method);
}

fn handleNewTextInput(_: *wl.Listener(*wlr.TextInputV3), wlr_text_input: *wlr.TextInputV3) void {
    TextInput.create(wlr_text_input) catch {
        log.err("out of memory", .{});
        wlr_text_input.resource.postNoMemory();
        return;
    };
}
