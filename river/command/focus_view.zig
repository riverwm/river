// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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

const std = @import("std");
const assert = std.debug.assert;
const fmt = std.fmt;

const server = &@import("../main.zig").server;

const Direction = @import("../command.zig").Direction;
const Error = @import("../command.zig").Error;
const Output = @import("../Output.zig");
const Seat = @import("../Seat.zig");
const View = @import("../View.zig");

/// Focus either the next or the previous visible view, depending on the enum
/// passed. Does nothing if there are 1 or 0 views in the stack.
pub fn focusView(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const direction = std.meta.stringToEnum(Direction, args[1]) orelse return Error.InvalidDirection;
    const output = seat.focused_output orelse return;

    if (seat.focused != .view) return;
    if (seat.focused.view.pending.fullscreen) return;

    if (focusViewTarget(seat, output, direction)) |target| {
        assert(!target.pending.fullscreen);
        seat.focus(target);
        server.root.applyPending();
    }
}

fn focusViewTarget(seat: *Seat, output: *Output, direction: Direction) ?*View {
    switch (direction) {
        inline else => |dir| {
            const it_dir = comptime switch (dir) {
                .next => .forward,
                .previous => .reverse,
            };
            var it = output.pending.wm_stack.iterator(it_dir);
            while (it.next()) |view| {
                if (view == seat.focused.view) break;
            } else {
                unreachable;
            }

            // Return the next view in the stack matching the tags if any.
            while (it.next()) |view| {
                if (output.pending.tags & view.pending.tags != 0) return view;
            }

            // Wrap and return the first view in the stack matching the tags if
            // any is found before completing the loop back to the focused view.
            while (it.next()) |view| {
                if (view == seat.focused.view) return null;
                if (output.pending.tags & view.pending.tags != 0) return view;
            }

            unreachable;
        },
    }
}

pub fn focusViewById(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    if (seat.focused != .view) return;
    if (seat.focused.view.pending.fullscreen) return;

    const id = fmt.parseInt(u8, args[1], 10) catch return;

    var it = server.root.views.iterator(.forward);
    while (it.next()) |view| {
        if (id == view.id) {
            seat.focusOutput(view.pending.output);
            seat.focus(view);
            server.root.applyPending();
        }
    }
}
