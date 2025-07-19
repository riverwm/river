// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2025 The River Developers
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

const KeyboardGroup = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");
const XkbBinding = @import("XkbBinding.zig");

const log = std.log.scoped(.input);

const KeyConsumer = union(enum) {
    /// Builtin compositor binding, e.g. VT switching
    builtin,
    /// A null value indicates that the xkb_binding_v1 was destroyed or that
    /// a press event was already sent due to a press on a different keyboard.
    binding: ?*XkbBinding,
    im_grab,
    /// Seat's focused client
    focus,
};

pub const Pressed = struct {
    const Key = struct {
        /// The raw libinput keycode, not the xkb keycode
        code: u32,
        consumer: KeyConsumer,
        count: u32,
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

    fn get(pressed: *Pressed, code: u32) ?*Key {
        for (pressed.keys.slice()) |*key| {
            if (key.code == code) return key;
        }
        return null;
    }

    fn add(pressed: *Pressed, new: Key) void {
        assert(pressed.get(new.code) == null);
        pressed.keys.appendAssumeCapacity(new);
    }

    /// Asserts that the key is present and has count == 0.
    fn remove(pressed: *Pressed, code: u32) KeyConsumer {
        for (pressed.keys.constSlice(), 0..) |key, idx| {
            if (key.code == code) {
                assert(key.count == 0);
                return pressed.keys.swapRemove(idx).consumer;
            }
        }
        unreachable;
    }
};

ref_count: u32 = 1,

seat: *Seat,
/// Seat.keyboard_groups
link: wl.list.Link,

virtual: bool,

/// This is the keyboard that actually gets passed to wlr_seat functions for
/// setting keyboard focus.
state: wlr.Keyboard,

/// Pressed keys along with where their press event has been sent
pressed: Pressed = .{},

key: wl.Listener(*wlr.Keyboard.event.Key) = .init(handleKey),
modifiers: wl.Listener(*wlr.Keyboard) = .init(handleModifiers),

pub fn create(seat: *Seat, keymap: ?*xkb.Keymap, virtual: bool) !*KeyboardGroup {
    const group = try util.gpa.create(KeyboardGroup);
    errdefer util.gpa.destroy(group);
    group.* = .{
        .seat = seat,
        .virtual = virtual,
        .state = undefined,
        .link = undefined,
    };
    seat.keyboard_groups.append(group);

    group.state.init(&.{
        .name = "river.KeyboardGroup",
        .led_update = null, // TODO
    }, "river.KeyboardGroup");
    group.state.data = group;

    // wlroots will log an error on failure, there's not much we can do to recover unfortunately.
    _ = group.state.setKeymap(keymap);
    group.state.setRepeatInfo(server.config.repeat_rate, server.config.repeat_delay);

    group.state.events.key.add(&group.key);
    group.state.events.modifiers.add(&group.modifiers);

    return group;
}

pub fn ref(group: *KeyboardGroup) *KeyboardGroup {
    group.ref_count += 1;
    return group;
}

pub fn unref(group: *KeyboardGroup) void {
    group.ref_count -= 1;
    if (group.ref_count > 0) {
        return;
    }

    group.link.remove();

    group.key.link.remove();
    group.modifiers.link.remove();

    // If the currently active keyboard of a seat is destroyed we need to set
    // a new active keyboard. Otherwise wlroots may send an enter event without
    // first having sent a keymap event if Seat.keyboardNotifyEnter() is called
    // before a new active keyboard is set.
    if (group.seat.wlr_seat.getKeyboard() == &group.state) {
        if (group.seat.keyboard_groups.first()) |other| {
            group.seat.wlr_seat.setKeyboard(&other.state);
        }
    }

    group.state.finish();

    util.gpa.destroy(group);
}

pub fn processKey(group: *KeyboardGroup, event: *const wlr.Keyboard.event.Key) void {
    if (group.pressed.get(event.keycode)) |key| {
        assert(key.count > 0);
        if (event.state == .pressed) {
            key.count += 1;
        } else {
            key.count -= 1;
            if (key.count == 0) {
                var key_event: wlr.Keyboard.event.Key = .{
                    .time_msec = event.time_msec,
                    .keycode = event.keycode,
                    .update_state = true,
                    .state = .released,
                };
                // Calls handleKey(), which will remove from pressed
                group.state.notifyKey(&key_event);
            }
        }
    } else if (event.state == .pressed) {
        if (group.pressed.keys.ensureUnusedCapacity(1)) {
            var key_event: wlr.Keyboard.event.Key = .{
                .time_msec = event.time_msec,
                .keycode = event.keycode,
                .update_state = true,
                .state = .pressed,
            };
            // Calls handleKey(), which will add to pressed
            group.state.notifyKey(&key_event);
        } else |_| {}
    }
    // Release events without a prior press event are ignored.
}

fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
    const group: *KeyboardGroup = @fieldParentPtr("key", listener);

    const xkb_state = group.state.xkb_state orelse {
        log.err("no xkb_state available", .{});
        return;
    };

    // Every sent press event, to a regular client or the input method, should have
    // the corresponding release event sent to the same client.
    // Similarly, no press event means no release event.
    const consumer: KeyConsumer = blk: {
        if (event.state == .released) {
            // Decision is made on press; release only follows it
            break :blk group.pressed.remove(event.keycode);
        }
        // Translate libinput keycode -> xkbcommon
        const xkb_keycode = event.keycode + 8;
        for (xkb_state.keyGetSyms(xkb_keycode)) |sym| {
            if (handleBuiltinBinding(sym)) {
                log.debug("matched builtin binding", .{});
                break :blk .builtin;
            }
        }
        const modifiers = group.state.getModifiers();
        if (group.seat.matchXkbBinding(xkb_keycode, modifiers, xkb_state)) |binding| {
            log.debug("matched xkb binding", .{});
            break :blk .{
                .binding = if (binding.sent_pressed) null else binding,
            };
        }
        if (group.getInputMethodGrab() != null) {
            break :blk .im_grab;
        }
        break :blk .focus;
    };

    if (event.state == .pressed) {
        group.pressed.add(.{
            .code = event.keycode,
            .consumer = consumer,
            .count = 1,
        });
    }

    switch (consumer) {
        .builtin => {},
        .binding => |b| if (b) |binding| {
            if (event.state == .pressed) {
                binding.pressed();
            } else {
                binding.released();
            }
        },
        .im_grab => if (group.getInputMethodGrab()) |keyboard_grab| {
            keyboard_grab.setKeyboard(&group.state);
            keyboard_grab.sendKey(event.time_msec, event.keycode, event.state);
        },
        .focus => {
            group.seat.wlr_seat.setKeyboard(&group.state);
            group.seat.wlr_seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
        },
    }
}

pub fn processModifiers(group: *KeyboardGroup, modifiers: wlr.Keyboard.Modifiers) void {
    group.state.notifyModifiers(modifiers);
}

fn handleModifiers(listener: *wl.Listener(*wlr.Keyboard), _: *wlr.Keyboard) void {
    const group: *KeyboardGroup = @fieldParentPtr("modifiers", listener);
    if (group.getInputMethodGrab()) |keyboard_grab| {
        keyboard_grab.setKeyboard(&group.state);
        keyboard_grab.sendModifiers(&group.state.modifiers);
    } else {
        group.seat.wlr_seat.setKeyboard(&group.state);
        group.seat.wlr_seat.keyboardNotifyModifiers(&group.state.modifiers);
    }
}

/// Handle any builtin, hardcoded compositor keybindings such as VT switching.
/// Returns true if the keysym was handled.
fn handleBuiltinBinding(keysym: xkb.Keysym) bool {
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
/// or if the group is for a virtual keyboard.
/// TODO: it would be good if virtual keyboards that are not associated with the
/// input method client would pass through the input method grab.
/// See https://gitlab.freedesktop.org/wlroots/wlroots/-/issues/2322
fn getInputMethodGrab(group: *KeyboardGroup) ?*wlr.InputMethodV2.KeyboardGrab {
    if (group.virtual) {
        return null;
    }
    if (group.seat.relay.input_method) |input_method| {
        if (input_method.keyboard_grab) |keyboard_grab| {
            return keyboard_grab;
        }
    }
    return null;
}

pub fn processKeymap(group: *KeyboardGroup, keymap: *xkb.Keymap) void {
    // wlroots will log an error on failure, there's not much we can do to recover unfortunately.
    _ = group.state.setKeymap(keymap);
}
