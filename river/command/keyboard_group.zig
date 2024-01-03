// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2022 The River Developers
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
const mem = std.mem;

const globber = @import("globber");

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");
const KeyboardGroup = @import("../KeyboardGroup.zig");

pub fn keyboardGroupCreate(
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    if (keyboardGroupFromName(seat, args[1]) != null) {
        const msg = try util.gpa.dupe(u8, "error: failed to create keybaord group: group of same name already exists\n");
        out.* = msg;
        return;
    }

    try KeyboardGroup.create(seat, args[1]);
}

pub fn keyboardGroupDestroy(
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;
    const group = keyboardGroupFromName(seat, args[1]) orelse {
        const msg = try util.gpa.dupe(u8, "error: no keyboard group with that name exists\n");
        out.* = msg;
        return;
    };
    group.destroy();
}

pub fn keyboardGroupAdd(
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 3) return Error.TooManyArguments;

    const group = keyboardGroupFromName(seat, args[1]) orelse {
        const msg = try util.gpa.dupe(u8, "error: no keyboard group with that name exists\n");
        out.* = msg;
        return;
    };
    try globber.validate(args[2]);
    try group.addIdentifier(args[2]);
}

pub fn keyboardGroupRemove(
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 3) return Error.TooManyArguments;

    const group = keyboardGroupFromName(seat, args[1]) orelse {
        const msg = try util.gpa.dupe(u8, "error: no keyboard group with that name exists\n");
        out.* = msg;
        return;
    };
    try group.removeIdentifier(args[2]);
}

fn keyboardGroupFromName(seat: *Seat, name: []const u8) ?*KeyboardGroup {
    var it = seat.keyboard_groups.first;
    while (it) |node| : (it = node.next) {
        if (mem.eql(u8, node.data.name, name)) return &node.data;
    }
    return null;
}
