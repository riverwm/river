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
        .up => view.move(0, -delta),
        .down => view.move(0, delta),
        .left => view.move(-delta, 0),
        .right => view.move(delta, 0),
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
    const border_width = server.config.border_width;
    var output_width: i32 = undefined;
    var output_height: i32 = undefined;
    view.output.wlr_output.effectiveResolution(&output_width, &output_height);
    switch (direction) {
        .up => view.pending.box.y = border_width,
        .down => view.pending.box.y = output_height - view.pending.box.height - border_width,
        .left => view.pending.box.x = border_width,
        .right => view.pending.box.x = output_width - view.pending.box.width - border_width,
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
    var output_width: i32 = undefined;
    var output_height: i32 = undefined;
    view.output.wlr_output.effectiveResolution(&output_width, &output_height);
    switch (orientation) {
        .horizontal => {
            const prev_width = view.pending.box.width;
            view.pending.box.width += delta;
            view.applyConstraints();
            // Get width difference after applying view constraints, so that the
            // move reflects the actual size difference, but before applying the
            // output size constraints, to allow growing a view even if it is
            // up against an output edge.
            const diff_width = prev_width - view.pending.box.width;
            // Do not grow bigger than the output
            view.pending.box.width = @min(
                view.pending.box.width,
                output_width - 2 * server.config.border_width,
            );
            view.move(@divFloor(diff_width, 2), 0);
        },
        .vertical => {
            const prev_height = view.pending.box.height;
            view.pending.box.height += delta;
            view.applyConstraints();
            const diff_height = prev_height - view.pending.box.height;
            // Do not grow bigger than the output
            view.pending.box.height = @min(
                view.pending.box.height,
                output_height - 2 * server.config.border_width,
            );
            view.move(0, @divFloor(diff_height, 2));
        },
    }

    apply(view);
}

fn apply(view: *View) void {
    // Set the view to floating but keep the position and dimensions, if their
    // dimensions are set by a layout generator. If however the views are
    // unarranged, leave them as non-floating so the next active layout can
    // affect them.
    if (view.output.pending.layout != null)
        view.pending.float = true;

    view.float_box = view.pending.box;

    view.applyPending();
}

fn getView(seat: *Seat) ?*View {
    if (seat.focused != .view) return null;
    const view = seat.focused.view;

    // Do not touch fullscreen views
    if (view.pending.fullscreen) return null;

    return view;
}
