// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
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

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

/// Spawn a program.
pub fn spawn(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    failure_message: *[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;

    const cmd = try std.mem.join(allocator, " ", args[1..]);
    defer allocator.free(cmd);

    const child_args = [_][]const u8{ "/bin/sh", "-c", cmd };
    const child = try std.ChildProcess.init(&child_args, allocator);
    defer child.deinit();

    std.ChildProcess.spawn(child) catch |err| {
        failure_message.* = try std.fmt.allocPrint(
            allocator,
            "failed to spawn {}: {}.",
            .{ cmd, err },
        );
        return Error.CommandFailed;
    };
}
