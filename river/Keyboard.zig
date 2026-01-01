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
    repeat_rate: u31 = 80,
    /// Repeat delay in milliseconds
    repeat_delay: u31 = 300,

    pub fn eql(a: *const Config, b: *const Config) bool {
        // TODO this probably isn't a sufficient way to compare keymaps?
        return a.keymap == b.keymap and
            a.repeat_rate == b.repeat_rate and
            a.repeat_delay == b.repeat_delay;
    }
};

device: InputDevice,
device_destroyed: bool = false,
queued_events: u32 = 0,

virtual: bool,
config: Config,
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
        .virtual = virtual,
        .config = .{
            .keymap = if (virtual) wlr_keyboard.keymap else server.config.keymap,
        },
        .device = undefined,
    };
    try keyboard.device.init(seat, wlr_device, virtual);
    errdefer keyboard.device.deinit();

    wlr_keyboard.data = keyboard;

    wlr_keyboard.events.key.add(&keyboard.key);
    wlr_keyboard.events.modifiers.add(&keyboard.modifiers);
    wlr_keyboard.events.keymap.add(&keyboard.keymap);

    return keyboard;
}

pub fn setGroup(keyboard: *Keyboard) void {
    assert(keyboard.group == null);
    const seat = keyboard.device.seat;
    if (keyboard.virtual) {
        // Virtual keyboards set their own keymap and require independent modifier state.
        // Therefore, they are always placed in their own group of one.
        keyboard.group = KeyboardGroup.create(seat, keyboard.config, true) catch |err| switch (err) {
            error.OutOfMemory => blk: {
                log.err("out of memory", .{});
                break :blk null;
            },
        };
    } else {
        var it = seat.keyboard_groups.iterator(.forward);
        while (it.next()) |group| {
            if (keyboard.config.eql(&group.config)) {
                keyboard.group = group.ref();
                break;
            }
        } else {
            keyboard.group = KeyboardGroup.create(seat, keyboard.config, false) catch |err| switch (err) {
                error.OutOfMemory => blk: {
                    log.err("out of memory", .{});
                    break :blk null;
                },
            };
        }
    }
}

pub fn setRepeatInfo(keyboard: *Keyboard, rate: u31, delay: u31) void {
    assert(!keyboard.virtual);
    keyboard.config.repeat_rate = rate;
    keyboard.config.repeat_delay = delay;
    if (keyboard.group) |group| {
        group.unref();
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

    if (keyboard.group) |group| group.unref();

    util.gpa.destroy(keyboard);
}

pub fn dropEvent(keyboard: *Keyboard) void {
    keyboard.queued_events -= 1;
    keyboard.maybeDestroy();
}

pub fn processKey(keyboard: *Keyboard, key: *const wlr.Keyboard.event.Key) void {
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
