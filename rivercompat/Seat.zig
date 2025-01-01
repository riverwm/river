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

const Seat = @This();

const std = @import("std");
const assert = std.debug.assert;
const wayland = @import("wayland");
const xkb = @import("xkbcommon");
const wl = wayland.client.wl;
const river = wayland.client.river;

const c = @import("c.zig");

const Window = @import("Window.zig");
const WindowManager = @import("WindowManager.zig");
const XkbBinding = @import("XkbBinding.zig");
const PointerBinding = @import("PointerBinding.zig");

const gpa = std.heap.c_allocator;

wm: *WindowManager,
seat_v1: *river.SeatV1,
focused: ?*Window = null,
link: wl.list.Link,

pub fn create(wm: *WindowManager, seat_v1: *river.SeatV1) void {
    const seat = gpa.create(Seat) catch @panic("OOM");
    seat.* = .{
        .wm = wm,
        .seat_v1 = seat_v1,
        .link = undefined,
    };
    wm.seats.append(seat);

    seat_v1.setListener(*Seat, handleEvent, seat);

    XkbBinding.create(seat, xkb.Keysym.n, .{ .mod4 = true }, .focus_next);
    XkbBinding.create(seat, xkb.Keysym.h, .{ .mod4 = true }, .hide_focused);
    XkbBinding.create(seat, xkb.Keysym.s, .{ .mod4 = true }, .show_all);
    PointerBinding.create(seat, c.BTN_LEFT, .{ .mod4 = true }, .move_start, .move_end);
    PointerBinding.create(seat, c.BTN_MIDDLE, .{ .mod4 = true }, .close_focused, null);
}

pub fn focus(seat: *Seat, target: ?*Window) void {
    if (target) |window| {
        seat.seat_v1.focusWindow(window.window_v1);
        seat.focused = window;

        window.link.remove();
        seat.wm.windows.prepend(window);

        window.node_v1.placeTop();
    } else {
        seat.seat_v1.clearFocus();
    }
}

pub fn focusNext(seat: *Seat) void {
    if (seat.focused != null) {
        if (seat.wm.windows.length() >= 2) {
            seat.focus(seat.wm.windows.last().?);
        }
    } else {
        seat.focus(seat.wm.windows.first());
    }
}

fn handleEvent(seat_v1: *river.SeatV1, event: river.SeatV1.Event, seat: *Seat) void {
    assert(seat.seat_v1 == seat_v1);
    switch (event) {
        .removed => {
            seat_v1.destroy();
            gpa.destroy(seat);
        },
        .pointer_enter => {},
        .pointer_leave => {},
        .pointer_activity => {},
        .window_interaction => |args| {
            const window_v1 = args.window orelse return;
            const window: *Window = @ptrCast(@alignCast(window_v1.getUserData()));
            seat.focus(window);
        },
    }
}

pub const Action = enum {
    focus_next,
    close_focused,
    hide_focused,
    show_all,
    move_start,
    move_end,
};

pub fn execute(seat: *Seat, action: Action) void {
    switch (action) {
        .focus_next => seat.focusNext(),
        .close_focused => if (seat.focused) |window| window.window_v1.close(),
        .hide_focused => if (seat.focused) |window| window.window_v1.hide(),
        .show_all => {
            var it = seat.wm.windows.iterator(.forward);
            while (it.next()) |window| {
                window.window_v1.show();
            }
        },
        .move_start => {
            seat.seat_v1.opStartPointer();
            var it = seat.wm.windows.iterator(.forward);
            while (it.next()) |window| {
                seat.seat_v1.opAddMoveWindow(window.window_v1);
            }
        },
        .move_end => seat.seat_v1.opEnd(),
    }
}
