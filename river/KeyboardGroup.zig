// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const KeyboardGroup = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Keyboard = @import("Keyboard.zig");
const Seat = @import("Seat.zig");
const XkbBinding = @import("XkbBinding.zig");
const InputDevice = @import("InputDevice.zig");

const log = std.log.scoped(.input);

const KeyConsumer = union(enum) {
    /// Builtin compositor binding, e.g. VT switching
    builtin,
    /// A null value indicates that the xkb_binding_v1 was destroyed or that
    /// a press event was already sent due to a press on a different keyboard.
    binding: ?*XkbBinding,
    /// The river_xkb_bindings_seat_v1.ensure_next_key_eaten request caused
    /// the key to be eaten.
    ensure_eaten,
    im_grab,
    /// Seat's focused client
    focus,
};

const Press = struct {
    consumer: KeyConsumer,
    count: u32,
};

pub const pressed_count_max = 32;
comptime {
    // wlroots uses a buffer of length 32 to track pressed keys and does not track pressed
    // keys beyond that limit. It seems likely that this can cause some inconsistency within
    // wlroots in the case that someone has 32 fingers and the hardware supports N-key rollover.
    //
    // Furthermore, wlroots will continue to forward key press/release events to river if more
    // than 32 keys are pressed. Therefore river chooses to ignore keypresses that would take
    // the keyboard beyond 32 simultaneously pressed keys.
    assert(pressed_count_max == @typeInfo(std.meta.fieldInfo(wlr.Keyboard, .keycodes).type).array.len);
}

ref_count: u32 = 1,

seat: *Seat,
/// Seat.keyboard_groups
link: wl.list.Link,

virtual: bool,

config: Keyboard.Config,

/// This is the keyboard that actually gets passed to wlr_seat functions for
/// setting keyboard focus.
state: wlr.Keyboard,

/// Maps from pressed libinput keycode (not xkb keycode) to information
/// about where the press event has been sent.
pressed: std.AutoArrayHashMapUnmanaged(u32, Press) = .empty,

key: wl.Listener(*wlr.Keyboard.event.Key) = .init(handleKey),
modifiers: wl.Listener(*wlr.Keyboard) = .init(handleModifiers),

pub fn create(seat: *Seat, config: Keyboard.Config, virtual: bool) !*KeyboardGroup {
    const group = try util.gpa.create(KeyboardGroup);
    errdefer util.gpa.destroy(group);
    group.* = .{
        .seat = seat,
        .virtual = virtual,
        .config = config,
        .state = undefined,
        .link = undefined,
    };

    try group.pressed.ensureTotalCapacity(util.gpa, pressed_count_max);
    errdefer comptime unreachable;

    seat.keyboard_groups.append(group);

    group.state.init(&.{
        .name = "river.KeyboardGroup",
        .led_update = null, // TODO
    }, "river.KeyboardGroup");
    group.state.data = group;

    // wlroots will log an error on failure, there's not much we can do to recover unfortunately.
    _ = group.state.setKeymap(config.keymap);
    group.state.setRepeatInfo(config.repeat_rate, config.repeat_delay);

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

    group.pressed.deinit(util.gpa);

    util.gpa.destroy(group);
}

pub fn match(group: *const KeyboardGroup, config: *Keyboard.Config) bool {
    const a = &group.config;
    const b = config;
    if (a.repeat_rate != b.repeat_rate) return false;
    if (a.repeat_delay != b.repeat_delay) return false;

    if (a.keymap == b.keymap) return true;
    if (a.keymap == null or b.keymap == null) return false;

    // Can't get away with a cheap pointer comparison.
    // TODO implement a non-terrible way to do this upstream in xkbcommon
    const a_string = a.keymap.?.getAsString2(.use_original_format, .{});
    defer std.c.free(a_string);
    const b_string = b.keymap.?.getAsString2(.use_original_format, .{});
    defer std.c.free(b_string);
    if (a_string == null or b_string == null) {
        // Ugh, no good options here, we don't know why the function failed.
        // xkbcommon really needs a better API for this.
        log.err("xkb_keymap_get_as_string2() failed", .{});
        return false;
    }
    if (std.mem.orderZ(u8, a_string.?, b_string.?) == .eq) {
        // Consolidate so we don't have to do this expensive/silly comparison again
        config.keymap.?.unref();
        config.keymap = group.config.keymap.?.ref();
        return true;
    }
    return false;
}

pub fn processKey(group: *KeyboardGroup, event: *const wlr.Keyboard.event.Key) void {
    if (group.pressed.getPtr(event.keycode)) |key| {
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
        if (group.pressed.count() < pressed_count_max) {
            var key_event: wlr.Keyboard.event.Key = .{
                .time_msec = event.time_msec,
                .keycode = event.keycode,
                .update_state = true,
                .state = .pressed,
            };
            // Calls handleKey(), which will add to pressed
            group.state.notifyKey(&key_event);
        }
    }
    // Release events without a prior press event are ignored.
}

fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
    const group: *KeyboardGroup = @fieldParentPtr("key", listener);

    const xkb_state = group.state.xkb_state orelse {
        log.err("no xkb_state available", .{});
        return;
    };

    {
        var it = group.seat.keyboard_groups.iterator(.forward);
        while (it.next()) |g| {
            for (g.pressed.values()) |press| {
                if (press.consumer != .binding) continue;
                const binding = press.consumer.binding orelse continue;
                binding.stopRepeat();
            }
        }
    }

    // Every sent press event, to a regular client or the input method, should have
    // the corresponding release event sent to the same client.
    // Similarly, no press event means no release event.
    const consumer: KeyConsumer = blk: {
        if (event.state == .released) {
            // Decision is made on press; release only follows it
            const kv = group.pressed.fetchSwapRemove(event.keycode).?;
            assert(kv.value.count == 0);
            break :blk kv.value.consumer;
        }
        // Translate libinput keycode -> xkbcommon
        const xkb_keycode = event.keycode + 8;
        const modifiers = group.state.getModifiers();
        for (xkb_state.keyGetSyms(xkb_keycode)) |sym| {
            if (handleBuiltinBinding(sym, modifiers)) {
                log.debug("matched builtin binding", .{});
                break :blk .builtin;
            }
        }
        if (group.seat.matchXkbBinding(xkb_keycode, modifiers, xkb_state)) |binding| {
            log.debug("matched xkb binding", .{});
            group.seat.xkb_bindings_seat.ensure_next_key_eaten = false;
            break :blk .{
                .binding = if (binding.sent_pressed) null else binding,
            };
        }
        if (group.seat.xkb_bindings_seat.ensure_next_key_eaten) {
            // This approach for filtering out modifiers feels like a hack.
            // Open questions:
            // - Are there keycodes that should be considered a modifier which
            //   are not yet checked by keysymIsModifier()?
            // - Is it possible to test whether keysymIsModifier() is complete?
            // - Is there a way to test the effect the keycode would have on
            //   the active modifiers of the xkb_state?
            // - Could we add a function to libxkbcommon to make that possible?
            for (xkb_state.keyGetSyms(xkb_keycode)) |sym| {
                if (!keysymIsModifier(sym)) {
                    group.seat.xkb_bindings_seat.ensure_next_key_eaten = false;
                    break :blk .ensure_eaten;
                }
            }
        }
        if (group.getInputMethodGrab() != null) {
            break :blk .im_grab;
        }
        break :blk .focus;
    };

    if (event.state == .pressed) {
        group.pressed.putAssumeCapacityNoClobber(event.keycode, .{
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
        .ensure_eaten => {
            if (event.state == .pressed) {
                group.seat.xkb_bindings_seat.scheduled.ate_unbound_key = true;
                server.wm.dirtyWindowing();
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

    group.sendState();
}

fn keysymIsModifier(keysym: xkb.Keysym) bool {
    switch (@intFromEnum(keysym)) {
        xkb.Keysym.Shift_L,
        xkb.Keysym.Shift_R,
        xkb.Keysym.Control_L,
        xkb.Keysym.Control_R,
        xkb.Keysym.Caps_Lock,
        xkb.Keysym.Shift_Lock,

        xkb.Keysym.Meta_L,
        xkb.Keysym.Meta_R,
        xkb.Keysym.Alt_L,
        xkb.Keysym.Alt_R,
        xkb.Keysym.Super_L,
        xkb.Keysym.Super_R,
        xkb.Keysym.Hyper_L,
        xkb.Keysym.Hyper_R,

        xkb.Keysym.Num_Lock,

        xkb.Keysym.ISO_Lock,
        xkb.Keysym.ISO_Level2_Latch,
        xkb.Keysym.ISO_Level3_Shift,
        xkb.Keysym.ISO_Level3_Latch,
        xkb.Keysym.ISO_Level3_Lock,
        xkb.Keysym.ISO_Level5_Shift,
        xkb.Keysym.ISO_Level5_Latch,
        xkb.Keysym.ISO_Level5_Lock,
        xkb.Keysym.ISO_Group_Shift,
        xkb.Keysym.ISO_Group_Latch,
        xkb.Keysym.ISO_Group_Lock,
        xkb.Keysym.ISO_Next_Group,
        xkb.Keysym.ISO_Next_Group_Lock,
        xkb.Keysym.ISO_Prev_Group,
        xkb.Keysym.ISO_Prev_Group_Lock,
        xkb.Keysym.ISO_First_Group,
        xkb.Keysym.ISO_First_Group_Lock,
        xkb.Keysym.ISO_Last_Group,
        xkb.Keysym.ISO_Last_Group_Lock,
        => return true,
        else => return false,
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
    group.sendState();
}

/// Handle any builtin, hardcoded compositor keybindings such as VT switching.
/// Returns true if the keysym was handled.
fn handleBuiltinBinding(keysym: xkb.Keysym, modifiers: wlr.Keyboard.ModifierMask) bool {
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
        xkb.Keysym.Delete => {
            if (modifiers == wlr.Keyboard.ModifierMask{ .ctrl = true, .alt = true }) {
                log.debug("ctrl+alt+delete pressed, exiting...", .{});
                server.wl_server.terminate();
                return true;
            } else {
                return false;
            }
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

pub fn sendState(group: *KeyboardGroup) void {
    const keymap = group.config.keymap.?;
    const layout_index = group.state.modifiers.group;
    const layout_name = keymap.layoutGetName(layout_index);
    const caps_mask = keymap.modGetMask(xkb.names.mod.caps);
    const capslock = group.state.modifiers.locked & caps_mask != 0;
    const num_mask = keymap.modGetMask(xkb.names.vmod.num);
    const numlock = group.state.modifiers.locked & num_mask != 0;

    var it = server.xkb_config.keyboards.iterator(.forward);
    while (it.next()) |xkb_keyboard| {
        const device: *InputDevice = @fieldParentPtr("xkb_keyboard", xkb_keyboard);
        const keyboard: *Keyboard = @fieldParentPtr("device", device);
        if (keyboard.group != group) continue;

        xkb_keyboard.sendState(layout_index, layout_name, capslock, numlock);
    }
}
