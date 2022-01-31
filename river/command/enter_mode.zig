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

const server = &@import("../main.zig").server;

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

/// Switch to the given mode
pub fn enterMode(
    allocator: std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    if (seat.mode_id == 1) {
        out.* = try std.fmt.allocPrint(
            allocator,
            "manually exiting mode 'locked' is not allowed",
            .{},
        );
        return Error.Other;
    }

    const target_mode = args[1];
    const mode_id = server.config.mode_to_id.get(target_mode) orelse {
        out.* = try std.fmt.allocPrint(
            allocator,
            "cannot enter non-existant mode '{s}'",
            .{target_mode},
        );
        return Error.Other;
    };

    if (mode_id == 1) {
        out.* = try std.fmt.allocPrint(
            allocator,
            "manually entering mode 'locked' is not allowed",
            .{},
        );
        return Error.Other;
    }

    seat.mode_id = mode_id;
}
