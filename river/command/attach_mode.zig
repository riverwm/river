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
const mem = std.mem;

const server = &@import("../main.zig").server;

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");
const AttachMode = @import("../Config.zig").AttachMode;

fn parseAttachMode(args: []const [:0]const u8) Error!AttachMode {
    if (args.len < 2) return Error.NotEnoughArguments;

    if (mem.eql(u8, "top", args[1])) {
        return if (args.len > 2) Error.TooManyArguments else .top;
    } else if (mem.eql(u8, "bottom", args[1])) {
        return if (args.len > 2) Error.TooManyArguments else .bottom;
    } else if (mem.eql(u8, "after", args[1])) {
        if (args.len < 3) return Error.NotEnoughArguments;
        if (args.len > 3) return Error.TooManyArguments;
        return .{ .after = try std.fmt.parseInt(usize, args[2], 10) };
    }
    return Error.UnknownOption;
}

pub fn outputAttachMode(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    const output = seat.focused_output orelse return;
    output.attach_mode = try parseAttachMode(args);
}

pub fn defaultAttachMode(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    server.config.default_attach_mode = try parseAttachMode(args);
}
