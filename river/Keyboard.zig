// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 - 2025 The River Developers
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

const Keyboard = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const InputDevice = @import("InputDevice.zig");
const KeyboardGroup = @import("KeyboardGroup.zig");
const Seat = @import("Seat.zig");

const log = std.log.scoped(.input);

device: InputDevice,
device_destroyed: bool = false,
queued_events: u32 = 0,

group: *KeyboardGroup,

key: wl.Listener(*wlr.Keyboard.event.Key) = .init(queueKey),
modifiers: wl.Listener(*wlr.Keyboard) = .init(queueModifiers),
keymap: wl.Listener(*wlr.Keyboard) = .init(queueKeymap),

pub fn create(seat: *Seat, wlr_device: *wlr.InputDevice, virtual: bool) !*Keyboard {
    const keyboard = try util.gpa.create(Keyboard);
    errdefer util.gpa.destroy(keyboard);

    keyboard.* = .{
        .device = undefined,
        .group = undefined,
    };
    try keyboard.device.init(seat, wlr_device);
    errdefer keyboard.device.deinit();

    const wlr_keyboard = keyboard.device.wlr_device.toKeyboard();
    wlr_keyboard.data = keyboard;

    keyboard.group = blk: {
        if (virtual) {
            // Virtual keyboards set their own keymap and require independent modifier state.
            // Therefore, they are always placed in their own group of one.
            break :blk try KeyboardGroup.create(seat, wlr_keyboard.keymap, true);
        } else {
            var it = seat.keyboard_groups.iterator(.forward);
            while (it.next()) |group| {
                // TODO input configuration will require sorting keyboards into
                // groups based on keymap and repeat info.
                if (true) {
                    break :blk group.ref();
                }
            }
            break :blk try KeyboardGroup.create(seat, server.config.keymap, false);
        }
    };

    wlr_keyboard.events.key.add(&keyboard.key);
    wlr_keyboard.events.modifiers.add(&keyboard.modifiers);
    wlr_keyboard.events.keymap.add(&keyboard.keymap);

    return keyboard;
}

pub fn deviceDestroy(keyboard: *Keyboard) void {
    assert(!keyboard.device_destroyed);
    keyboard.device_destroyed = true;

    keyboard.key.link.remove();
    keyboard.modifiers.link.remove();
    keyboard.keymap.link.remove();

    keyboard.device.deinit();

    keyboard.maybeDestroy();
}

fn maybeDestroy(keyboard: *Keyboard) void {
    if (!keyboard.device_destroyed or keyboard.queued_events > 0) {
        return;
    }

    keyboard.group.unref();

    util.gpa.destroy(keyboard);
}

pub fn processKey(keyboard: *Keyboard, key: *const wlr.Keyboard.event.Key) void {
    keyboard.group.processKey(key);
    keyboard.queued_events -= 1;
    keyboard.maybeDestroy();
}

pub fn processModifiers(keyboard: *Keyboard, modifiers: wlr.Keyboard.Modifiers) void {
    keyboard.group.processModifiers(modifiers);
    keyboard.queued_events -= 1;
    keyboard.maybeDestroy();
}

pub fn processKeymap(keyboard: *Keyboard, keymap: *xkb.Keymap) void {
    defer keymap.unref();
    keyboard.group.processKeymap(keymap);
    keyboard.queued_events -= 1;
    keyboard.maybeDestroy();
}

fn queueKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
    const keyboard: *Keyboard = @fieldParentPtr("key", listener);
    assert(!keyboard.device_destroyed);
    keyboard.queued_events += 1;
    keyboard.device.seat.queueEvent(.{ .keyboard_key = .{
        .keyboard = keyboard,
        .key = event.*,
    } }) catch {
        keyboard.queued_events -= 1;
    };
}

fn queueModifiers(listener: *wl.Listener(*wlr.Keyboard), _: *wlr.Keyboard) void {
    const keyboard: *Keyboard = @fieldParentPtr("modifiers", listener);
    assert(!keyboard.device_destroyed);
    const wlr_keyboard = keyboard.device.wlr_device.toKeyboard();
    keyboard.queued_events += 1;
    keyboard.device.seat.queueEvent(.{ .keyboard_modifiers = .{
        .keyboard = keyboard,
        .modifiers = wlr_keyboard.modifiers,
    } }) catch {
        keyboard.queued_events -= 1;
    };
}

fn queueKeymap(listener: *wl.Listener(*wlr.Keyboard), _: *wlr.Keyboard) void {
    const keyboard: *Keyboard = @fieldParentPtr("keymap", listener);
    assert(!keyboard.device_destroyed);
    const wlr_keyboard = keyboard.device.wlr_device.toKeyboard();
    const keymap = wlr_keyboard.keymap orelse return;
    keyboard.queued_events += 1;
    keyboard.device.seat.queueEvent(.{ .keyboard_keymap = .{
        .keyboard = keyboard,
        .keymap = keymap.ref(),
    } }) catch {
        keyboard.queued_events -= 1;
        keymap.unref();
    };
}
