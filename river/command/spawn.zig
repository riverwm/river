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
const os = std.os;
const mem = std.mem;
const fmt = std.fmt;
const wlr = @import("wlr");
const flags = @import("flags");

const c = @import("../c.zig");
const util = @import("../util.zig");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

const server = &@import("../main.zig").server;

/// Spawn a program.
pub fn spawn(
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    const result = flags.parser([:0]const u8, &.{
        .{ .name = "current-tags", .kind = .boolean },
    }).parse(args[1..]) catch {
        return error.InvalidOption;
    };
    if (result.args.len < 1) return Error.NotEnoughArguments;
    if (result.args.len > 1) return Error.TooManyArguments;

    var token: ?[:0]const u8 = null;
    if (result.flags.@"current-tags") {
        var now: os.timespec = undefined;
        os.clock_gettime(os.CLOCK.MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
        token = try fmt.allocPrintZ(util.gpa, "!river-{}-{}", .{
            (seat.focused_output orelse return).pending.tags,
            now.tv_nsec,
        });
        // TODO find out whether the string we punch into this function needs to
        //      remain allocated after we return from this call site.
        _ = server.xdg_activation.addToken(token.?) orelse unreachable;
    }
    //defer if (token) |t| util.gpa.free(t);

    const child_args = [_:null]?[*:0]const u8{ "/bin/sh", "-c", result.args[0], null };

    const pid = os.fork() catch {
        out.* = try std.fmt.allocPrint(util.gpa, "fork/execve failed", .{});
        return Error.Other;
    };

    if (pid == 0) {
        if (result.flags.@"current-tags") {
            std.debug.assert(token != null);
            _ = c.setenv("XDG_ACTIVATION_TOKEN", token.?.ptr, 1);
        }
        util.post_fork_pre_execve();
        const pid2 = os.fork() catch c._exit(1);
        if (pid2 == 0) os.execveZ("/bin/sh", &child_args, std.c.environ) catch c._exit(1);

        c._exit(0);
    }

    // Wait the intermediate child.
    const ret = os.waitpid(pid, 0);
    if (!os.W.IFEXITED(ret.status) or
        (os.W.IFEXITED(ret.status) and os.W.EXITSTATUS(ret.status) != 0))
    {
        out.* = try std.fmt.allocPrint(util.gpa, "fork/execve failed", .{});
        return Error.Other;
    }
}
