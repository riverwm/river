// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const PointerBinding = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const c = @import("c.zig").c;
const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");

const log = std.log.scoped(.input);

seat: *Seat,
object: *river.PointerBindingV1,

button: u32,
modifiers: river.SeatV1.Modifiers,

wm_scheduled: struct {
    state_change: enum {
        none,
        pressed,
        released,
    } = .none,
} = .{},
wm_requested: struct {
    enabled: bool = false,
} = .{},

/// This bit of state is used to ensure that multiple simultaneous
/// presses across multiple keyboards do not cause multiple press
/// events to be sent to the window manager.
sent_pressed: bool = false,

/// Seat.pointer_bindings
link: wl.list.Link,

pub fn create(
    seat: *Seat,
    client: *wl.Client,
    version: u32,
    id: u32,
    button: u32,
    modifiers: river.SeatV1.Modifiers,
) !void {
    const binding = try util.gpa.create(PointerBinding);
    errdefer util.gpa.destroy(binding);

    const pointer_binding_v1 = try river.PointerBindingV1.create(client, version, id);
    errdefer comptime unreachable;

    log.debug("new river_pointer_binding_v1: button: {d}({?s}) modifiers: {d}", .{
        button,
        @as(?[*:0]const u8, c.libevdev_event_code_get_name(c.EV_KEY, button)),
        @as(u32, @bitCast(modifiers)),
    });

    binding.* = .{
        .seat = seat,
        .object = pointer_binding_v1,
        .button = button,
        .modifiers = modifiers,
        .link = undefined,
    };
    pointer_binding_v1.setHandler(*PointerBinding, handleRequest, handleDestroy, binding);

    seat.pointer_bindings.append(binding);
}

pub fn destroy(binding: *PointerBinding) void {
    binding.object.setHandler(?*anyopaque, handleRequestInert, null, null);
    handleDestroy(binding.object, binding);
}

fn handleRequestInert(
    pointer_binding_v1: *river.PointerBindingV1,
    request: river.PointerBindingV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) pointer_binding_v1.destroy();
}

fn handleDestroy(_: *river.PointerBindingV1, binding: *PointerBinding) void {
    if (binding.seat.cursor.pressed.getPtr(binding.button)) |value_ptr| {
        // It is possible for the window manager to create duplicate pointer bindings.
        if (value_ptr.* == binding) {
            value_ptr.* = null;
        }
    }

    binding.link.remove();
    util.gpa.destroy(binding);
}

fn handleRequest(
    pointer_binding_v1: *river.PointerBindingV1,
    request: river.PointerBindingV1.Request,
    binding: *PointerBinding,
) void {
    assert(binding.object == pointer_binding_v1);
    switch (request) {
        .destroy => pointer_binding_v1.destroy(),
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

pub fn pressed(binding: *PointerBinding) void {
    assert(!binding.sent_pressed);
    // Input event processing should not continue after a press/release event
    // until that event is sent to the window manager in an update and acked.
    assert(binding.wm_scheduled.state_change == .none);
    binding.wm_scheduled.state_change = .pressed;
    server.wm.dirtyWindowing();
}

pub fn released(binding: *PointerBinding) void {
    assert(binding.sent_pressed);
    // Input event processing should not continue after a press/release event
    // until that event is sent to the window manager in an update and acked.
    assert(binding.wm_scheduled.state_change == .none);
    binding.wm_scheduled.state_change = .released;
    server.wm.dirtyWindowing();
}

pub fn match(
    binding: *const PointerBinding,
    button: u32,
    modifiers: wlr.Keyboard.ModifierMask,
) bool {
    if (!binding.wm_requested.enabled) return false;

    return button == binding.button and
        @as(u32, @bitCast(modifiers)) == @as(u32, @bitCast(binding.modifiers));
}
