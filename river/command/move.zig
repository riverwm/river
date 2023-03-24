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
const math = std.math;

const server = &@import("../main.zig").server;

const Error = @import("../command.zig").Error;
const PhysicalDirection = @import("../command.zig").PhysicalDirection;
const Orientation = @import("../command.zig").Orientation;
const Seat = @import("../Seat.zig");
const View = @import("../View.zig");

pub fn move(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 3) return Error.TooManyArguments;

    const delta = try std.fmt.parseInt(i32, args[2], 10);
    const direction = std.meta.stringToEnum(PhysicalDirection, args[1]) orelse
        return Error.InvalidPhysicalDirection;

    const view = getView(seat) orelse return;
    switch (direction) {
        .up => view.pending_delta.y -|= delta,
        .down => view.pending_delta.y +|= delta,
        .left => view.pending_delta.x -|= delta,
        .right => view.pending_delta.x +|= delta,
    }

    apply(view);
}

pub fn snap(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const direction = std.meta.stringToEnum(PhysicalDirection, args[1]) orelse
        return Error.InvalidPhysicalDirection;

    const view = getView(seat) orelse return;

    switch (direction) {
        .up => view.pending_delta.y = std.math.minInt(i32),
        .down => view.pending_delta.y = std.math.maxInt(i32),
        .left => view.pending_delta.x = std.math.minInt(i32),
        .right => view.pending_delta.x = std.math.maxInt(i32),
    }

    apply(view);
}

pub fn resize(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 3) return Error.TooManyArguments;

    const delta = try std.fmt.parseInt(i32, args[2], 10);
    const orientation = std.meta.stringToEnum(Orientation, args[1]) orelse
        return Error.InvalidOrientation;

    const view = getView(seat) orelse return;

    switch (orientation) {
        .horizontal => {
            view.pending_delta.width +|= delta;
            view.pending_delta.x -|= @divFloor(delta, 2);
        },
        .vertical => {
            view.pending_delta.height +|= delta;
            view.pending_delta.y -|= @divFloor(delta, 2);
        },
    }

    apply(view);
}

fn apply(view: *View) void {
    // Set the view to floating but keep the position and dimensions, if their
    // dimensions are set by a layout generator. If however the views are
    // unarranged, leave them as non-floating so the next active layout can
    // affect them.
    if (view.pending.output == null or view.pending.output.?.layout != null) {
        view.pending.float = true;
    }

    server.root.applyPending();
}

fn getView(seat: *Seat) ?*View {
    if (seat.focused != .view) return null;
    const view = seat.focused.view;

    // Do not touch fullscreen views
    if (view.pending.fullscreen) return null;

    return view;
}
