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

const XkbBinding = @This();

const std = @import("std");
const assert = std.debug.assert;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Seat = @import("Seat.zig");
const Window = @import("Window.zig");

const gpa = std.heap.c_allocator;

seat: *Seat,
xkb_binding_v1: *river.XkbBindingV1,

pub fn create(
    seat: *Seat,
    keysym: u32,
    modifiers: river.SeatV1.Modifiers,
) void {
    const xkb_binding_v1 = seat.seat_v1.getXkbBinding(keysym, modifiers) catch @panic("OOM");
    const binding = gpa.create(XkbBinding) catch @panic("OOM");
    binding.* = .{
        .seat = seat,
        .xkb_binding_v1 = xkb_binding_v1,
    };
    xkb_binding_v1.setListener(*XkbBinding, handleEvent, binding);
    xkb_binding_v1.enable();
}

fn handleEvent(xkb_binding_v1: *river.XkbBindingV1, event: river.XkbBindingV1.Event, binding: *XkbBinding) void {
    assert(binding.xkb_binding_v1 == xkb_binding_v1);
    switch (event) {
        .pressed => {
            binding.seat.focusNext();
        },
        .released => {},
    }
}
