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

const Output = @import("Output.zig");
const Window = @import("Window.zig");
const XkbBinding = @import("XkbBinding.zig");
const PointerBinding = @import("PointerBinding.zig");

const wm = &@import("root").wm;
const gpa = std.heap.c_allocator;

const State = struct {
    new: bool = false,
    action: ?Action = null,
    window_interaction: ?*Window = null,
    shell_surface_interaction: ?*river.ShellSurfaceV1 = null,
};

seat_v1: *river.SeatV1,
pending: State = .{},
focused: ?*Window = null,
focused_output: ?*Output = null,
link: wl.list.Link,

pub fn create(seat_v1: *river.SeatV1) void {
    const seat = gpa.create(Seat) catch @panic("OOM");
    seat.* = .{
        .seat_v1 = seat_v1,
        .pending = .{ .new = true },
        .link = undefined,
    };
    wm.seats.append(seat);

    seat_v1.setListener(*Seat, handleEvent, seat);
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
            assert(seat.pending.window_interaction == null);
            seat.pending.window_interaction = window;
        },
        .shell_surface_interaction => |args| {
            assert(seat.pending.shell_surface_interaction == null);
            seat.pending.shell_surface_interaction = args.shell_surface orelse return;
        },
    }
}

pub fn updateWindowing(seat: *Seat) void {
    if (seat.pending.new) {
        seat.focused_output = wm.outputs.first();

        XkbBinding.create(seat, xkb.Keysym.n, .{ .mod4 = true }, .focus_next);
        XkbBinding.create(seat, xkb.Keysym.h, .{ .mod4 = true }, .hide_focused);
        XkbBinding.create(seat, xkb.Keysym.k, .{ .mod4 = true }, .close_focused);
        XkbBinding.create(seat, xkb.Keysym.s, .{ .mod4 = true }, .show_all);
        PointerBinding.create(seat, c.BTN_LEFT, .{ .mod4 = true }, .move_start, .op_end);
        PointerBinding.create(seat, c.BTN_RIGHT, .{ .mod4 = true }, .resize_start, .op_end);
        PointerBinding.create(seat, c.BTN_MIDDLE, .{ .mod4 = true }, .close_focused, null);
    }
    if (seat.pending.window_interaction) |window| {
        seat.focus(window);
    }
    if (seat.pending.shell_surface_interaction) |shell_surface| {
        seat.seat_v1.focusShellSurface(shell_surface);
    }
    if (seat.pending.action) |action| {
        seat.execute(action);
    }
    seat.pending = .{};
}

pub const Action = enum {
    focus_next,
    close_focused,
    hide_focused,
    show_all,
    move_start,
    resize_start,
    op_end,
};

pub fn execute(seat: *Seat, action: Action) void {
    switch (action) {
        .focus_next => {}, // XXX
        .close_focused => if (seat.focused) |window| window.window_v1.close(),
        .hide_focused => if (seat.focused) |window| window.window_v1.hide(),
        .show_all => {
            var it = wm.windows.iterator(.forward);
            while (it.next()) |window| {
                window.window_v1.show();
            }
        },
        .move_start => {
            seat.seat_v1.opStartPointer();
            var it = wm.windows.iterator(.forward);
            while (it.next()) |window| {
                seat.seat_v1.opAddMoveWindow(window.window_v1);
            }
        },
        .resize_start => {
            seat.seat_v1.opStartPointer();
            var it = wm.windows.iterator(.forward);
            while (it.next()) |window| {
                seat.seat_v1.opAddResizeWindow(window.window_v1, .{
                    .top = true,
                    .left = true,
                });
            }
        },
        .op_end => seat.seat_v1.opEnd(),
    }
}

pub fn focus(seat: *Seat, _target: ?*Window) void {
    if (seat.focused_output == null) return;
    if (wm.session_locked) return;

    var target = _target;
    if (target) |window| {
        if (window.output == null or window.output.?.tags & window.tags == 0) {
            target = null;
        } else if (window.output.? != seat.focused_output.?) {
            seat.focused_output = window.output;
        }
    }

    if (target == null) {
        var it = seat.focused_output.?.stack_focus.iterator(.forward);
        while (it.next()) |window| {
            if (window.tags & seat.focused_output.?.tags != 0) {
                target = window;
                break;
            }
        }
    }

    if (target) |window| {
        window.link_focus.remove();
        seat.focused_output.?.stack_focus.prepend(window);
        seat.seat_v1.focusWindow(window.window_v1);
    } else {
        seat.seat_v1.clearFocus();
    }
}
