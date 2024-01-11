// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 - 2024 The River Developers
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
const globber = @import("globber");

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

    // Add to keyboard-group, if applicable.
    var group_it = seat.keyboard_groups.first;
    outer: while (group_it) |group_node| : (group_it = group_node.next) {
        for (group_node.data.globs.items) |glob| {
            if (globber.match(glob, self.device.identifier)) {
                // wlroots will log an error if this fails explaining the reason.
                _ = group_node.data.wlr_group.addKeyboard(wlr_keyboard);
                break :outer;
            }
        }
    }

    wlr_keyboard.setRepeatInfo(server.config.repeat_rate, server.config.repeat_delay);

    wlr_keyboard.events.key.add(&self.key);
    wlr_keyboard.events.modifiers.add(&self.modifiers);
}

pub fn deinit(self: *Self) void {
    self.key.link.remove();
    self.modifiers.link.remove();

    const seat = self.device.seat;
    const wlr_keyboard = self.device.wlr_device.toKeyboard();

    self.device.deinit();

    // If the currently active keyboard of a seat is destroyed we need to set
    // a new active keyboard. Otherwise wlroots may send an enter event without
    // first having sent a keymap event if Seat.keyboardNotifyEnter() is called
    // before a new active keyboard is set.
    if (seat.wlr_seat.getKeyboard() == wlr_keyboard) {
        var it = server.input_manager.devices.iterator(.forward);
        while (it.next()) |device| {
            if (device.seat == seat and device.wlr_device.type == .keyboard) {
                seat.wlr_seat.setKeyboard(device.wlr_device.toKeyboard());
            }
        }
    }

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

    for (keysyms) |sym| {
        if (!released and handleBuiltinMapping(sym)) return;
    }

    // If we sent a pressed event to the client we should send the matching release event as well,
    // even if the release event triggers a mapping or would otherwise be sent to an input method.
    const sent_to_client = blk: {
        if (released and !self.eaten_keycodes.remove(event.keycode)) {
            const wlr_seat = self.device.seat.wlr_seat;
            wlr_seat.setKeyboard(self.device.wlr_device.toKeyboard());
            wlr_seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
            break :blk true;
        } else {
            break :blk false;
        }
    };

    if (self.device.seat.handleMapping(keycode, modifiers, released, xkb_state)) {
        if (!released) self.eaten_keycodes.add(event.keycode);
    } else if (self.getInputMethodGrab()) |keyboard_grab| {
        if (!released) self.eaten_keycodes.add(event.keycode);

        if (!sent_to_client) {
            keyboard_grab.setKeyboard(keyboard_grab.keyboard);
            keyboard_grab.sendKey(event.time_msec, event.keycode, event.state);
        }
    } else if (!sent_to_client) {
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

    if (self.getInputMethodGrab()) |keyboard_grab| {
        keyboard_grab.setKeyboard(keyboard_grab.keyboard);
        keyboard_grab.sendModifiers(&wlr_keyboard.modifiers);
    } else {
        self.device.seat.wlr_seat.setKeyboard(self.device.wlr_device.toKeyboard());
        self.device.seat.wlr_seat.keyboardNotifyModifiers(&wlr_keyboard.modifiers);
    }
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

/// Returns null if the keyboard is not grabbed by an input method,
/// or if event is from a virtual keyboard of the same client as the grab.
/// TODO: see https://gitlab.freedesktop.org/wlroots/wlroots/-/issues/2322
fn getInputMethodGrab(self: Self) ?*wlr.InputMethodV2.KeyboardGrab {
    if (self.device.seat.relay.input_method) |input_method| {
        if (input_method.keyboard_grab) |keyboard_grab| {
            if (self.device.wlr_device.getVirtualKeyboard()) |virtual_keyboard| {
                if (virtual_keyboard.resource.getClient() == keyboard_grab.resource.getClient()) {
                    return null;
                }
            }
            return keyboard_grab;
        }
    }
    return null;
}
