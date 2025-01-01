// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2024 The River Developers
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

const PointerBinding = @This();

const std = @import("std");
const assert = std.debug.assert;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Seat = @import("Seat.zig");
const Window = @import("Window.zig");

const gpa = std.heap.c_allocator;

seat: *Seat,
pointer_binding_v1: *river.PointerBindingV1,
press_action: Seat.Action,
release_action: ?Seat.Action,

pub fn create(
    seat: *Seat,
    button: u32,
    modifiers: river.SeatV1.Modifiers,
    press_action: Seat.Action,
    release_action: ?Seat.Action,
) void {
    const pointer_binding_v1 = seat.seat_v1.getPointerBinding(button, modifiers) catch @panic("OOM");
    const binding = gpa.create(PointerBinding) catch @panic("OOM");
    binding.* = .{
        .seat = seat,
        .pointer_binding_v1 = pointer_binding_v1,
        .press_action = press_action,
        .release_action = release_action,
    };
    pointer_binding_v1.setListener(*PointerBinding, handleEvent, binding);
    pointer_binding_v1.enable();
}

fn handleEvent(pointer_binding_v1: *river.PointerBindingV1, event: river.PointerBindingV1.Event, binding: *PointerBinding) void {
    assert(binding.pointer_binding_v1 == pointer_binding_v1);
    switch (event) {
        .pressed => binding.seat.execute(binding.press_action),
        .released => if (binding.release_action) |a| binding.seat.execute(a),
    }
}
