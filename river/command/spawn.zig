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

const c = @import("../c.zig");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

/// Spawn a program.
pub fn spawn(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;

    const cmd = try std.mem.join(allocator, " ", args[1..]);
    defer allocator.free(cmd);
    const cmdZ = try std.cstr.addNullByte(allocator, cmd);
    defer allocator.free(cmdZ);

    const child_args = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmdZ, null };

    const pid = std.os.fork() catch {
        out.* = try std.fmt.allocPrint(allocator, "fork/execve failed", .{});
        return Error.Other;
    };

    if (pid == 0) {
        // Clean things up for the child in an intermediate fork
        if (c.setsid() < 0) unreachable;
        if (std.os.system.sigprocmask(std.os.SIG_SETMASK, &std.os.empty_sigset, null) < 0) unreachable;

        const pid2 = std.os.fork() catch std.os.exit(1);
        if (pid2 == 0) std.os.execveZ("/bin/sh", &child_args, std.c.environ) catch std.os.exit(1);

        std.os.exit(0);
    }

    // Wait the intermediate child.
    const status = std.os.waitpid(pid, 0);
    if (std.os.WIFEXITED(status) and std.os.WEXITSTATUS(status) != 0) {
        out.* = try std.fmt.allocPrint(allocator, "fork/execve failed", .{});
        return Error.Other;
    }
}
