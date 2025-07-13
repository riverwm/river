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

const Keyboard = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const globber = @import("globber");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const InputDevice = @import("InputDevice.zig");
const Seat = @import("Seat.zig");
const XkbBinding = @import("XkbBinding.zig");

const log = std.log.scoped(.input);

pub const Event = union(enum) {
    key: wlr.Keyboard.event.Key,
    modifiers: wlr.Keyboard.Modifiers,
};

const KeyConsumer = union(enum) {
    /// A null value indicates that the xkb_binding_v1 was destroyed or that
    /// a press event was already sent due to a press on a different keyboard.
    binding: ?*XkbBinding,
    im_grab,
    /// Seat's focused client
    focus,
};

pub const Pressed = struct {
    const Key = struct {
        code: u32,
        consumer: KeyConsumer,
    };

    pub const capacity = 32;

    comptime {
        // wlroots uses a buffer of length 32 to track pressed keys and does not track pressed
        // keys beyond that limit. It seems likely that this can cause some inconsistency within
        // wlroots in the case that someone has 32 fingers and the hardware supports N-key rollover.
        //
        // Furthermore, wlroots will continue to forward key press/release events to river if more
        // than 32 keys are pressed. Therefore river chooses to ignore keypresses that would take
        // the keyboard beyond 32 simultaneously pressed keys.
        assert(capacity == @typeInfo(std.meta.fieldInfo(wlr.Keyboard, .keycodes).type).array.len);
    }

    keys: std.BoundedArray(Key, capacity) = .{},

    fn contains(pressed: *Pressed, code: u32) bool {
        for (pressed.keys.constSlice()) |item| {
            if (item.code == code) return true;
        }
        return false;
    }

    fn addAssumeCapacity(pressed: *Pressed, new: Key) void {
        assert(!pressed.contains(new.code));
        pressed.keys.appendAssumeCapacity(new);
    }

    fn remove(pressed: *Pressed, code: u32) ?KeyConsumer {
        for (pressed.keys.constSlice(), 0..) |item, idx| {
            if (item.code == code) return pressed.keys.swapRemove(idx).consumer;
        }

        return null;
    }
};

device: InputDevice,

/// Pressed keys along with where their press event has been sent
pressed: Pressed = .{},

key: wl.Listener(*wlr.Keyboard.event.Key) = .init(queueKey),
modifiers: wl.Listener(*wlr.Keyboard) = .init(queueModifiers),

pub fn init(keyboard: *Keyboard, seat: *Seat, wlr_device: *wlr.InputDevice) !void {
    keyboard.* = .{
        .device = undefined,
    };
    try keyboard.device.init(seat, wlr_device);
    errdefer keyboard.device.deinit();

    const wlr_keyboard = keyboard.device.wlr_device.toKeyboard();
    wlr_keyboard.data = keyboard;

    // wlroots will log a more detailed error if this fails.
    if (!wlr_keyboard.setKeymap(server.config.keymap)) return error.OutOfMemory;

    if (wlr.KeyboardGroup.fromKeyboard(wlr_keyboard) == null) {
        // wlroots will log an error on failure
        _ = seat.keyboard_group.addKeyboard(wlr_keyboard);
    }

    wlr_keyboard.setRepeatInfo(server.config.repeat_rate, server.config.repeat_delay);

    wlr_keyboard.events.key.add(&keyboard.key);
    wlr_keyboard.events.modifiers.add(&keyboard.modifiers);
}

pub fn deinit(keyboard: *Keyboard) void {
    keyboard.key.link.remove();
    keyboard.modifiers.link.remove();

    const seat = keyboard.device.seat;
    const wlr_keyboard = keyboard.device.wlr_device.toKeyboard();

    keyboard.device.deinit();

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

    keyboard.* = undefined;
}

pub fn processKey(keyboard: *Keyboard, event: *const wlr.Keyboard.event.Key) void {
    const wlr_keyboard = keyboard.device.wlr_device.toKeyboard();

    // Translate libinput keycode -> xkbcommon
    const xkb_keycode = event.keycode + 8;

    // XXX this is not ok, we need to store current modifiers per-Keyboard ourselves
    const modifiers = wlr_keyboard.getModifiers();
    const released = event.state == .released;

    const xkb_state = wlr_keyboard.xkb_state orelse return;

    const keysyms = xkb_state.keyGetSyms(xkb_keycode);

    for (keysyms) |sym| {
        if (!released and handleBuiltinMapping(sym)) return;
    }

    // Some virtual_keyboard clients are buggy and press a key twice without
    // releasing it in between. There is no good way for river to handle this
    // other than to ignore any newer presses. No need to worry about pairing
    // the correct release, as the client is unlikely to send all of them
    // (and we already ignore releasing keys we don't know were pressed).
    if (!released and keyboard.pressed.contains(xkb_keycode)) {
        log.err("key pressed again without release, virtual-keyboard client bug?", .{});
        return;
    }

    // Every sent press event, to a regular client or the input method, should have
    // the corresponding release event sent to the same client.
    // Similarly, no press event means no release event.

    const consumer: KeyConsumer = blk: {
        // Decision is made on press; release only follows it
        if (released) {
            // The released key might not be in the pressed set when switching from a different tty
            // or if the press was ignored due to >32 keys being pressed simultaneously.
            break :blk keyboard.pressed.remove(xkb_keycode) orelse return;
        }

        // Ignore key presses beyond 32 simultaneously pressed keys (see comments in Pressed).
        // We must ensure capacity before calling handleMapping() to ensure that we either run
        // both the press and release mapping for certain key or neither mapping.
        keyboard.pressed.keys.ensureUnusedCapacity(1) catch return;

        if (keyboard.device.seat.matchXkbBinding(xkb_keycode, modifiers, xkb_state)) |binding| {
            log.debug("matched xkb binding", .{});
            break :blk .{
                .binding = if (binding.sent_pressed) null else binding,
            };
        } else if (keyboard.getInputMethodGrab() != null) {
            break :blk .im_grab;
        }

        break :blk .focus;
    };

    if (!released) {
        keyboard.pressed.addAssumeCapacity(.{ .code = xkb_keycode, .consumer = consumer });
    }

    switch (consumer) {
        .binding => |b| if (b) |binding| {
            if (released) {
                binding.released();
            } else {
                binding.pressed();
            }
        },
        .im_grab => if (keyboard.getInputMethodGrab()) |keyboard_grab| {
            keyboard_grab.setKeyboard(keyboard_grab.keyboard);
            keyboard_grab.sendKey(event.time_msec, event.keycode, event.state);
        },
        .focus => {
            const wlr_seat = keyboard.device.seat.wlr_seat;
            wlr_seat.setKeyboard(keyboard.device.wlr_device.toKeyboard());
            wlr_seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
        },
    }
}

pub fn processModifiers(keyboard: *Keyboard, modifiers: *const wlr.Keyboard.Modifiers) void {
    if (keyboard.getInputMethodGrab()) |keyboard_grab| {
        keyboard_grab.setKeyboard(keyboard_grab.keyboard);
        keyboard_grab.sendModifiers(modifiers);
    } else {
        keyboard.device.seat.wlr_seat.setKeyboard(keyboard.device.wlr_device.toKeyboard());
        keyboard.device.seat.wlr_seat.keyboardNotifyModifiers(modifiers);
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
                std.log.info("switching to VT {}", .{vt});
                session.changeVt(vt) catch std.log.err("changing VT failed", .{});
            }
            return true;
        },
        else => return false,
    }
}

/// Returns null if the keyboard is not grabbed by an input method,
/// or if event is from a virtual keyboard of the same client as the grab.
/// TODO: see https://gitlab.freedesktop.org/wlroots/wlroots/-/issues/2322
fn getInputMethodGrab(keyboard: Keyboard) ?*wlr.InputMethodV2.KeyboardGrab {
    if (keyboard.device.seat.relay.input_method) |input_method| {
        if (input_method.keyboard_grab) |keyboard_grab| {
            if (keyboard.device.wlr_device.getVirtualKeyboard()) |virtual_keyboard| {
                if (virtual_keyboard.resource.getClient() == keyboard_grab.resource.getClient()) {
                    return null;
                }
            }
            return keyboard_grab;
        }
    }
    return null;
}

fn queueKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
    const keyboard: *Keyboard = @fieldParentPtr("key", listener);
    const wlr_keyboard = keyboard.device.wlr_device.toKeyboard();

    // If the keyboard is in a group, this event will be handled by the group's Keyboard instance.
    if (wlr_keyboard.group != null) return;

    keyboard.device.seat.queueEvent(.{ .keyboard_key = .{ .keyboard = keyboard, .key = event.* } });
}

fn queueModifiers(listener: *wl.Listener(*wlr.Keyboard), wlr_keyboard: *wlr.Keyboard) void {
    const keyboard: *Keyboard = @fieldParentPtr("modifiers", listener);

    // If the keyboard is in a group, this event will be handled by the group's Keyboard instance.
    if (wlr_keyboard.group != null) return;

    keyboard.device.seat.queueEvent(.{ .keyboard_modifiers = .{ .keyboard = keyboard, .modifiers = wlr_keyboard.modifiers } });
}
