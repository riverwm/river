// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const util = @import("../util.zig");

const server = &@import("../main.zig").server;

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

pub fn attachMode(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    if (std.mem.eql(u8, "top", args[1])) {
        server.config.attach_mode = .top;
    } else if (std.mem.eql(u8, "bottom", args[1])) {
        server.config.attach_mode = .bottom;
    } else {
        return Error.UnknownOption;
    }
}
