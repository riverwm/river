// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

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

pub const Config = struct {
    keymap: ?*xkb.Keymap,
    /// Repeat rate in characters per second
    repeat_rate: u31 = 40,
    /// Repeat delay in milliseconds
    repeat_delay: u31 = 400,
};

device: InputDevice,
device_destroyed: bool = false,
queued_events: u32 = 0,

config: Config,

/// Set of pressed keys that have been processed by processKey().
/// Not equivalent to wlr_keyboard.keycodes.
/// This state is necessary to handle removing keyboards from groups properly.
pressed: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
/// Only null during initialization or due to allocation failure.
group: ?*KeyboardGroup = null,

key: wl.Listener(*wlr.Keyboard.event.Key) = .init(queueKey),
modifiers: wl.Listener(*wlr.Keyboard) = .init(queueModifiers),
keymap: wl.Listener(*wlr.Keyboard) = .init(queueKeymap),

pub fn create(seat: *Seat, wlr_device: *wlr.InputDevice, virtual: bool) !*Keyboard {
    const wlr_keyboard = wlr_device.toKeyboard();

    const keyboard = try util.gpa.create(Keyboard);
    errdefer util.gpa.destroy(keyboard);

    keyboard.* = .{
        .config = .{
            .keymap = blk: {
                if (virtual) {
                    if (wlr_keyboard.keymap) |keymap| {
                        break :blk keymap.ref();
                    } else {
                        break :blk null;
                    }
                } else {
                    break :blk server.xkb_config.default_keymap.ref();
                }
            },
        },
        .device = undefined,
    };
    errdefer if (keyboard.config.keymap) |keymap| keymap.unref();

    try keyboard.pressed.ensureTotalCapacity(util.gpa, KeyboardGroup.pressed_count_max);
    errdefer keyboard.pressed.deinit(util.gpa);

    try keyboard.device.init(seat, wlr_device, virtual);
    errdefer keyboard.device.deinit();

    wlr_keyboard.data = keyboard;

    wlr_keyboard.events.key.add(&keyboard.key);
    wlr_keyboard.events.modifiers.add(&keyboard.modifiers);

    if (virtual) {
        wlr_keyboard.events.keymap.add(&keyboard.keymap);
    } else {
        keyboard.keymap.link.init();
        if (shouldSetKeymap()) {
            _ = wlr_keyboard.setKeymap(keyboard.config.keymap);
        }
    }

    return keyboard;
}

// We don't want to ever set a keymap for backend-created wlr.Keyboards.
// Setting a keymap means that modifiers will be buggy and LEDs will be out of sync.
// However, if we don't set a keymap we don't get modifiers events from the backend
// at all currently due to a wlroots bug. This is even worse, so set a keymap
// despite the bugginess for backends that generate keyboard modifiers events.
// TODO(wlroots) https://gitlab.freedesktop.org/wlroots/wlroots/-/merge_requests/5324
fn shouldSetKeymap() bool {
    var wayland_or_x11: bool = false;
    server.backend.multiForEachBackend(*bool, shouldSetKeymapIter, &wayland_or_x11);
    return wayland_or_x11;
}

fn shouldSetKeymapIter(backend: *wlr.Backend, wayland_or_x11: *bool) void {
    if (backend.isWl() or (wlr.config.has_x11_backend and backend.isX11())) {
        wayland_or_x11.* = true;
    }
}

pub fn setGroup(keyboard: *Keyboard) void {
    assert(keyboard.group == null);
    const seat = keyboard.device.seat;
    // Virtual keyboards set their own keymap and require independent modifier state.
    // Therefore, they are always placed in their own group of one.
    if (!keyboard.device.virtual) {
        var it = seat.keyboard_groups.iterator(.forward);
        while (it.next()) |group| {
            if (group.match(&keyboard.config)) {
                keyboard.group = group.ref();
                return;
            }
        }
    }
    keyboard.group = KeyboardGroup.create(seat, keyboard.config, keyboard.device.virtual) catch |err| switch (err) {
        error.OutOfMemory => {
            log.err("out of memory", .{});
            return;
        },
    };
}

pub fn setRepeatInfo(keyboard: *Keyboard, rate: u31, delay: u31) void {
    assert(!keyboard.device.virtual);
    keyboard.config.repeat_rate = rate;
    keyboard.config.repeat_delay = delay;
    if (keyboard.group) |group| {
        group.unref(keyboard.pressed.keys());
        keyboard.group = null;
    }
    keyboard.setGroup();
}

pub fn setKeymap(keyboard: *Keyboard, keymap: *xkb.Keymap) void {
    assert(!keyboard.device.virtual);
    if (shouldSetKeymap()) {
        _ = keyboard.device.wlr_device.toKeyboard().setKeymap(keyboard.config.keymap);
    }
    if (keyboard.config.keymap) |old| old.unref();
    keyboard.config.keymap = keymap.ref();
    if (keyboard.group) |group| {
        group.unref(keyboard.pressed.keys());
        keyboard.group = null;
    }
    keyboard.setGroup();
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

    if (keyboard.config.keymap) |keymap| keymap.unref();
    if (keyboard.group) |group| group.unref(keyboard.pressed.keys());

    keyboard.pressed.deinit(util.gpa);
    util.gpa.destroy(keyboard);
}

pub fn dropEvent(keyboard: *Keyboard) void {
    keyboard.queued_events -= 1;
    keyboard.maybeDestroy();
}

pub fn processKey(keyboard: *Keyboard, key: *const wlr.Keyboard.event.Key) void {
    if (key.state == .released) {
        _ = keyboard.pressed.swapRemove(key.keycode);
    } else {
        assert(key.state == .pressed);
        if (keyboard.pressed.count() < KeyboardGroup.pressed_count_max) {
            keyboard.pressed.putAssumeCapacity(key.keycode, {});
        }
    }
    if (keyboard.group) |group| group.processKey(key);
    keyboard.dropEvent();
}

pub fn processModifiers(keyboard: *Keyboard, modifiers: wlr.Keyboard.Modifiers) void {
    if (keyboard.group) |group| group.processModifiers(modifiers);
    keyboard.dropEvent();
}

pub fn processKeymap(keyboard: *Keyboard, keymap: *xkb.Keymap) void {
    defer keymap.unref();
    if (keyboard.group) |group| group.processKeymap(keymap);
    keyboard.dropEvent();
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
