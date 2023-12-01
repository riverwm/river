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

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const KeycodeSet = @import("KeycodeSet.zig");
const Seat = @import("Seat.zig");
const InputDevice = @import("InputDevice.zig");

const log = std.log.scoped(.keyboard);

device: InputDevice,

/// Pressed keys for which a mapping was triggered on press
eaten_keycodes: KeycodeSet = .{},

key: wl.Listener(*wlr.Keyboard.event.Key) = wl.Listener(*wlr.Keyboard.event.Key).init(handleKey),
modifiers: wl.Listener(*wlr.Keyboard) = wl.Listener(*wlr.Keyboard).init(handleModifiers),

pub fn init(self: *Self, seat: *Seat, wlr_device: *wlr.InputDevice) !void {
    self.* = .{
        .device = undefined,
    };
    try self.device.init(seat, wlr_device);
    errdefer self.device.deinit();

    const wlr_keyboard = self.device.wlr_device.toKeyboard();
    wlr_keyboard.data = @intFromPtr(self);

    // wlroots will log a more detailed error if this fails.
    if (!wlr_keyboard.setKeymap(server.config.keymap)) return error.OutOfMemory;

    wlr_keyboard.setRepeatInfo(server.config.repeat_rate, server.config.repeat_delay);

    wlr_keyboard.events.key.add(&self.key);
    wlr_keyboard.events.modifiers.add(&self.modifiers);
}

pub fn deinit(self: *Self) void {
    self.key.link.remove();
    self.modifiers.link.remove();

    self.device.deinit();

    self.* = undefined;
}

fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
    // This event is raised when a key is pressed or released.
    const self = @fieldParentPtr(Self, "key", listener);
    const wlr_keyboard = self.device.wlr_device.toKeyboard();

    // If the keyboard is in a group, this event will be handled by the group's Keyboard instance.
    if (wlr_keyboard.group != null) return;

    self.device.seat.handleActivity();

    self.device.seat.clearRepeatingMapping();

    // Translate libinput keycode -> xkbcommon
    const keycode = event.keycode + 8;

    const modifiers = wlr_keyboard.getModifiers();
    const released = event.state == .released;

    // We must ref() the state here as a mapping could change the keyboard layout.
    const xkb_state = (wlr_keyboard.xkb_state orelse return).ref();
    defer xkb_state.unref();

    const keysyms = xkb_state.keyGetSyms(keycode);

    // Hide cursor when typing
    for (keysyms) |sym| {
        if (server.config.cursor_hide_when_typing == .enabled and
            !released and
            !isModifier(sym))
        {
            self.device.seat.cursor.hide();
            break;
        }
    }

    // Handle builtin mapping, only when keys are pressed
    for (keysyms) |sym| {
        if (!released and handleBuiltinMapping(sym)) return;
    }

    // Handle user-defined mappings
    const mapped = self.device.seat.hasMapping(keycode, modifiers, released, xkb_state);
    if (mapped) {
        if (!released) self.eaten_keycodes.add(event.keycode);

        const handled = self.device.seat.handleMapping(keycode, modifiers, released, xkb_state);
        assert(handled);
    }

    const eaten = if (released) self.eaten_keycodes.remove(event.keycode) else mapped;

    if (!eaten) {
        // If key was not handled, we pass it along to the client.
        const wlr_seat = self.device.seat.wlr_seat;
        wlr_seat.setKeyboard(self.device.wlr_device.toKeyboard());
        wlr_seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
    }
}

fn isModifier(keysym: xkb.Keysym) bool {
    return @intFromEnum(keysym) >= xkb.Keysym.Shift_L and @intFromEnum(keysym) <= xkb.Keysym.Hyper_R;
}

fn handleModifiers(listener: *wl.Listener(*wlr.Keyboard), _: *wlr.Keyboard) void {
    const self = @fieldParentPtr(Self, "modifiers", listener);
    const wlr_keyboard = self.device.wlr_device.toKeyboard();

    // If the keyboard is in a group, this event will be handled by the group's Keyboard instance.
    if (wlr_keyboard.group != null) return;

    self.device.seat.wlr_seat.setKeyboard(self.device.wlr_device.toKeyboard());
    self.device.seat.wlr_seat.keyboardNotifyModifiers(&wlr_keyboard.modifiers);
}

/// Handle any builtin, harcoded compsitor mappings such as VT switching.
/// Returns true if the keysym was handled.
fn handleBuiltinMapping(keysym: xkb.Keysym) bool {
    switch (@intFromEnum(keysym)) {
        xkb.Keysym.XF86Switch_VT_1...xkb.Keysym.XF86Switch_VT_12 => {
            log.debug("switch VT keysym received", .{});
            if (server.session) |session| {
                const vt = @intFromEnum(keysym) - xkb.Keysym.XF86Switch_VT_1 + 1;
                const log_server = std.log.scoped(.server);
                log_server.info("switching to VT {}", .{vt});
                session.changeVt(vt) catch log_server.err("changing VT failed", .{});
            }
            return true;
        },
        else => return false,
    }
}
