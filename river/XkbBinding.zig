// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const XkbBinding = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Keyboard = @import("Keyboard.zig");
const Seat = @import("Seat.zig");

const log = std.log.scoped(.input);

seat: *Seat,
object: *river.XkbBindingV1,

keysym: xkb.Keysym,
modifiers: river.SeatV1.Modifiers,

wm_scheduled: struct {
    state_change: enum {
        none,
        pressed,
        stop_repeat,
        released,
    } = .none,
} = .{},
wm_requested: struct {
    enabled: bool = false,
    // This is set for mappings with layout-pinning
    // If set, the layout with this index is always used to translate the given keycode
    layout: ?u32 = null,
} = .{},

/// This bit of state is used to ensure that multiple simultaneous
/// presses across multiple keyboards do not cause multiple press
/// events to be sent to the window manager.
sent_pressed: bool = false,

/// Seat.xkb_bindings
link: wl.list.Link,

pub fn create(
    seat: *Seat,
    client: *wl.Client,
    version: u32,
    id: u32,
    keysym: xkb.Keysym,
    modifiers: river.SeatV1.Modifiers,
) !void {
    const binding = try util.gpa.create(XkbBinding);
    errdefer util.gpa.destroy(binding);

    const xkb_binding_v1 = try river.XkbBindingV1.create(client, version, id);
    errdefer comptime unreachable;

    {
        var buffer: [64]u8 = undefined;
        const len = keysym.getName(&buffer, buffer.len);
        log.debug("new river_xkb_binding_v1: keysym: {d}({s}) modifiers: {d}", .{
            @intFromEnum(keysym),
            buffer[0..@max(0, len)],
            @as(u32, @bitCast(modifiers)),
        });
    }

    binding.* = .{
        .seat = seat,
        .object = xkb_binding_v1,
        .keysym = keysym,
        .modifiers = modifiers,
        .link = undefined,
    };
    xkb_binding_v1.setHandler(*XkbBinding, handleRequest, handleDestroy, binding);

    seat.xkb_bindings.append(binding);
}

pub fn destroy(binding: *XkbBinding) void {
    binding.object.setHandler(?*anyopaque, handleRequestInert, null, null);
    handleDestroy(binding.object, binding);
}

fn handleRequestInert(
    xkb_binding_v1: *river.XkbBindingV1,
    request: river.XkbBindingV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) xkb_binding_v1.destroy();
}

fn handleDestroy(_: *river.XkbBindingV1, binding: *XkbBinding) void {
    {
        var it = binding.seat.keyboard_groups.iterator(.forward);
        while (it.next()) |group| {
            for (group.pressed.values()) |*press| {
                if (press.consumer == .binding and press.consumer.binding == binding) {
                    press.consumer.binding = null;
                }
            }
        }
    }
    binding.link.remove();
    util.gpa.destroy(binding);
}

fn handleRequest(
    xkb_binding_v1: *river.XkbBindingV1,
    request: river.XkbBindingV1.Request,
    binding: *XkbBinding,
) void {
    assert(binding.object == xkb_binding_v1);
    switch (request) {
        .destroy => xkb_binding_v1.destroy(),
        .set_layout_override => |args| {
            if (!server.wm.ensureWindowing()) return;
            binding.wm_requested.layout = args.layout;
        },
        .enable => {
            if (!server.wm.ensureWindowing()) return;
            binding.wm_requested.enabled = true;
        },
        .disable => {
            if (!server.wm.ensureWindowing()) return;
            binding.wm_requested.enabled = false;
        },
    }
}

pub fn pressed(binding: *XkbBinding) void {
    assert(!binding.sent_pressed);
    // Input event processing should not continue after a state_change
    // until that event is sent to the window manager in an update and acked.
    assert(binding.wm_scheduled.state_change == .none);
    binding.wm_scheduled.state_change = .pressed;
    server.wm.dirtyWindowing();
}

pub fn stopRepeat(binding: *XkbBinding) void {
    assert(binding.sent_pressed);
    // Input event processing should not continue after a state change
    // until that event is sent to the window manager in an update and acked.
    assert(binding.wm_scheduled.state_change == .none);
    binding.wm_scheduled.state_change = .stop_repeat;
    server.wm.dirtyWindowing();
}

pub fn released(binding: *XkbBinding) void {
    assert(binding.sent_pressed);
    // stopRepeat() should always be called before released() by KeyboardGroup
    assert(binding.wm_scheduled.state_change == .stop_repeat);
    binding.wm_scheduled.state_change = .released;
    server.wm.dirtyWindowing();
}

/// Compare binding with given keycode, modifiers and keyboard state
pub fn match(
    binding: *const XkbBinding,
    keycode: xkb.Keycode,
    modifiers: wlr.Keyboard.ModifierMask,
    xkb_state: *xkb.State,
    method: enum { no_translate, translate },
) bool {
    if (!binding.wm_requested.enabled) return false;

    const keymap = xkb_state.getKeymap();

    // If the binding has no pinned layout, use the active layout.
    // It doesn't matter if the index is out of range, since xkbcommon
    // will fall back to the active layout if so.
    const layout = binding.wm_requested.layout orelse xkb_state.keyGetLayout(keycode);

    switch (method) {
        .no_translate => {
            // Get keysyms from the base layer, as if modifiers didn't change keysyms.
            // E.g. pressing `Super+Shift 1` does not translate to `Super Exclam`.
            const keysyms = keymap.keyGetSymsByLevel(
                keycode,
                layout,
                0,
            );

            if (@as(u32, @bitCast(modifiers)) == @as(u32, @bitCast(binding.modifiers))) {
                for (keysyms) |sym| {
                    if (sym == binding.keysym) {
                        return true;
                    }
                }
            }
        },
        .translate => {
            // Keysyms and modifiers as translated by xkb.
            // Modifiers used to translate the key are consumed.
            // E.g. pressing `Super+Shift 1` translates to `Super Exclam`.
            const keysyms_translated = keymap.keyGetSymsByLevel(
                keycode,
                layout,
                xkb_state.keyGetLevel(keycode, layout),
            );

            const consumed = xkb_state.keyGetConsumedMods2(keycode, .xkb);
            const modifiers_translated = @as(u32, @bitCast(modifiers)) & ~consumed;

            if (modifiers_translated == @as(u32, @bitCast(binding.modifiers))) {
                for (keysyms_translated) |sym| {
                    if (sym == binding.keysym) {
                        return true;
                    }
                }
            }
        },
    }

    return false;
}
