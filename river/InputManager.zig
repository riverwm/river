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

const Self = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const InputConfig = @import("InputConfig.zig");
const InputDevice = @import("InputDevice.zig");
const InputRelay = @import("InputRelay.zig");
const Keyboard = @import("Keyboard.zig");
const PointerConstraint = @import("PointerConstraint.zig");
const Seat = @import("Seat.zig");
const Switch = @import("Switch.zig");
const TextInput = @import("TextInput.zig");

const default_seat_name = "default";

const log = std.log.scoped(.input_manager);

new_input: wl.Listener(*wlr.InputDevice) = wl.Listener(*wlr.InputDevice).init(handleNewInput),

idle_notifier: *wlr.IdleNotifierV1,
relative_pointer_manager: *wlr.RelativePointerManagerV1,
virtual_pointer_manager: *wlr.VirtualPointerManagerV1,
virtual_keyboard_manager: *wlr.VirtualKeyboardManagerV1,
pointer_constraints: *wlr.PointerConstraintsV1,
input_method_manager: *wlr.InputMethodManagerV2,
text_input_manager: *wlr.TextInputManagerV3,

configs: std.ArrayList(InputConfig),
devices: wl.list.Head(InputDevice, .link),
seats: std.TailQueue(Seat) = .{},

exclusive_client: ?*wl.Client = null,

new_virtual_pointer: wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer) =
    wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer).init(handleNewVirtualPointer),
new_virtual_keyboard: wl.Listener(*wlr.VirtualKeyboardV1) =
    wl.Listener(*wlr.VirtualKeyboardV1).init(handleNewVirtualKeyboard),
new_constraint: wl.Listener(*wlr.PointerConstraintV1) =
    wl.Listener(*wlr.PointerConstraintV1).init(handleNewConstraint),
new_input_method: wl.Listener(*wlr.InputMethodV2) =
    wl.Listener(*wlr.InputMethodV2).init(handleNewInputMethod),
new_text_input: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleNewTextInput),

pub fn init(self: *Self) !void {
    const seat_node = try util.gpa.create(std.TailQueue(Seat).Node);
    errdefer util.gpa.destroy(seat_node);

    self.* = .{
        // These are automatically freed when the display is destroyed
        .idle_notifier = try wlr.IdleNotifierV1.create(server.wl_server),
        .relative_pointer_manager = try wlr.RelativePointerManagerV1.create(server.wl_server),
        .virtual_pointer_manager = try wlr.VirtualPointerManagerV1.create(server.wl_server),
        .virtual_keyboard_manager = try wlr.VirtualKeyboardManagerV1.create(server.wl_server),
        .pointer_constraints = try wlr.PointerConstraintsV1.create(server.wl_server),
        .input_method_manager = try wlr.InputMethodManagerV2.create(server.wl_server),
        .text_input_manager = try wlr.TextInputManagerV3.create(server.wl_server),
        .configs = std.ArrayList(InputConfig).init(util.gpa),

        .devices = undefined,
    };
    self.devices.init();

    self.seats.prepend(seat_node);
    try seat_node.data.init(default_seat_name);

    if (build_options.xwayland) server.xwayland.setSeat(self.defaultSeat().wlr_seat);

    server.backend.events.new_input.add(&self.new_input);
    self.virtual_pointer_manager.events.new_virtual_pointer.add(&self.new_virtual_pointer);
    self.virtual_keyboard_manager.events.new_virtual_keyboard.add(&self.new_virtual_keyboard);
    self.pointer_constraints.events.new_constraint.add(&self.new_constraint);
    self.input_method_manager.events.input_method.add(&self.new_input_method);
    self.text_input_manager.events.text_input.add(&self.new_text_input);
}

pub fn deinit(self: *Self) void {
    // This function must be called after the backend has been destroyed
    assert(self.devices.empty());

    self.new_virtual_pointer.link.remove();
    self.new_virtual_keyboard.link.remove();
    self.new_constraint.link.remove();
    self.new_input_method.link.remove();
    self.new_text_input.link.remove();

    while (self.seats.pop()) |seat_node| {
        seat_node.data.deinit();
        util.gpa.destroy(seat_node);
    }

    for (self.configs.items) |*config| {
        config.deinit();
    }
    self.configs.deinit();
}

pub fn defaultSeat(self: Self) *Seat {
    return &self.seats.first.?.data;
}

/// Returns true if input is currently allowed on the passed surface.
pub fn inputAllowed(self: Self, wlr_surface: *wlr.Surface) bool {
    return if (self.exclusive_client) |exclusive_client|
        exclusive_client == wlr_surface.resource.getClient()
    else
        true;
}

fn handleNewInput(listener: *wl.Listener(*wlr.InputDevice), wlr_device: *wlr.InputDevice) void {
    const self = @fieldParentPtr(Self, "new_input", listener);

    self.defaultSeat().addDevice(wlr_device);
}

fn handleNewVirtualPointer(
    listener: *wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer),
    event: *wlr.VirtualPointerManagerV1.event.NewPointer,
) void {
    const self = @fieldParentPtr(Self, "new_virtual_pointer", listener);

    // TODO Support multiple seats and don't ignore
    if (event.suggested_seat != null) {
        log.debug("Ignoring seat suggestion from virtual pointer", .{});
    }
    // TODO dont ignore output suggestion
    if (event.suggested_output != null) {
        log.debug("Ignoring output suggestion from virtual pointer", .{});
    }

    self.defaultSeat().addDevice(&event.new_pointer.pointer.base);
}

fn handleNewVirtualKeyboard(
    _: *wl.Listener(*wlr.VirtualKeyboardV1),
    virtual_keyboard: *wlr.VirtualKeyboardV1,
) void {
    const seat: *Seat = @ptrFromInt(virtual_keyboard.seat.data);
    seat.addDevice(&virtual_keyboard.keyboard.base);
}

fn handleNewConstraint(
    _: *wl.Listener(*wlr.PointerConstraintV1),
    wlr_constraint: *wlr.PointerConstraintV1,
) void {
    PointerConstraint.create(wlr_constraint) catch {
        log.err("out of memory", .{});
        wlr_constraint.resource.postNoMemory();
    };
}

fn handleNewInputMethod(
    _: *wl.Listener(*wlr.InputMethodV2),
    input_method: *wlr.InputMethodV2,
) void {
    //const self = @fieldParentPtr(Self, "new_input_method", listener);
    const seat = @as(*Seat, @ptrFromInt(input_method.seat.data));
    const relay = &seat.relay;

    // Only one input_method can be bound to a seat.
    if (relay.input_method != null) {
        log.debug("attempted to connect second input method to a seat", .{});
        input_method.sendUnavailable();
        return;
    }

    relay.input_method = input_method;

    input_method.events.commit.add(&relay.input_method_commit);
    input_method.events.grab_keyboard.add(&relay.grab_keyboard);
    input_method.events.destroy.add(&relay.input_method_destroy);

    log.debug("new input method on seat {s}", .{relay.seat.wlr_seat.name});

    if (seat.focused.surface()) |surface| {
        relay.focus(surface);
    }
}

fn handleNewTextInput(
    _: *wl.Listener(*wlr.TextInputV3),
    wlr_text_input: *wlr.TextInputV3,
) void {
    //const self = @fieldParentPtr(Self, "new_text_input", listener);
    const seat = @as(*Seat, @ptrFromInt(wlr_text_input.seat.data));
    const relay = &seat.relay;

    const text_input_node = util.gpa.create(std.TailQueue(TextInput).Node) catch {
        wlr_text_input.resource.postNoMemory();
        return;
    };
    text_input_node.data.init(relay, wlr_text_input);
    relay.text_inputs.append(text_input_node);

    log.debug("new text input on seat {s}", .{relay.seat.wlr_seat.name});
}
