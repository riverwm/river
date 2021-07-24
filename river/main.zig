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

const build_options = @import("build_options");
const std = @import("std");
const fs = std.fs;
const io = std.io;
const os = std.os;
const wlr = @import("wlroots");
const Args = @import("args").Args;
const FlagDef = @import("args").FlagDef;

const c = @import("c.zig");
const util = @import("util.zig");

const Server = @import("Server.zig");

pub var server: Server = undefined;

pub var level: std.log.Level = switch (std.builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe => .notice,
    .ReleaseFast => .err,
    .ReleaseSmall => .emerg,
};

const usage: []const u8 =
    \\Usage: river [options]
    \\
    \\  -h            Print this help message and exit.
    \\  -c <command>  Run `sh -c <command>` on startup.
    \\  -l <level>    Set the log level to a value from 0 to 7.
    \\  -version      Print the version number and exit.
    \\
;

pub fn main() anyerror!void {
    // This line is here because of https://github.com/ziglang/zig/issues/7807
    const argv: [][*:0]const u8 = os.argv;
    const args = Args(0, &[_]FlagDef{
        .{ .name = "-h", .kind = .boolean },
        .{ .name = "-version", .kind = .boolean },
        .{ .name = "-c", .kind = .arg },
        .{ .name = "-l", .kind = .arg },
    }).parse(argv[1..]);

    if (args.boolFlag("-h")) {
        try io.getStdOut().writeAll(usage);
        os.exit(0);
    }
    if (args.boolFlag("-version")) {
        try io.getStdOut().writeAll(@import("build_options").version);
        os.exit(0);
    }
    if (args.argFlag("-l")) |level_str| {
        const log_level = std.fmt.parseInt(u3, std.mem.span(level_str), 10) catch
            fatal("Error: invalid log level '{s}'", .{level_str});
        level = @intToEnum(std.log.Level, log_level);
    }
    const startup_command = blk: {
        if (args.argFlag("-c")) |command| {
            break :blk try util.gpa.dupeZ(u8, std.mem.span(command));
        } else {
            break :blk try defaultInitPath();
        }
    };

    wlr.log.init(switch (level) {
        .debug => .debug,
        .notice, .info => .info,
        .warn, .err, .crit, .alert, .emerg => .err,
    });

    std.log.info("initializing server", .{});
    try server.init();
    defer server.deinit();

    try server.start();

    // Run the child in a new process group so that we can send SIGTERM to all
    // descendants on exit.
    const child_pgid = if (startup_command) |cmd| blk: {
        std.log.info("running init executable '{s}'", .{cmd});
        const child_args = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd, null };
        const pid = try os.fork();
        if (pid == 0) {
            if (c.setsid() < 0) unreachable;
            if (os.system.sigprocmask(os.SIG_SETMASK, &os.empty_sigset, null) < 0) unreachable;
            os.execveZ("/bin/sh", &child_args, std.c.environ) catch c._exit(1);
        }
        util.gpa.free(cmd);
        // Since the child has called setsid, the pid is the pgid
        break :blk pid;
    } else null;
    defer if (child_pgid) |pgid| os.kill(-pgid, os.SIGTERM) catch |err| {
        std.log.err("failed to kill init process group: {s}", .{@errorName(err)});
    };

    std.log.info("running server", .{});

    server.wl_server.run();

    std.log.info("shutting down", .{});
}

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    io.getStdErr().writer().print(format ++ "\n", args) catch {};
    os.exit(1);
}

fn defaultInitPath() !?[:0]const u8 {
    const path = blk: {
        if (os.getenv("XDG_CONFIG_HOME")) |xdg_config_home| {
            break :blk try fs.path.joinZ(util.gpa, &[_][]const u8{ xdg_config_home, "river/init" });
        } else if (os.getenv("HOME")) |home| {
            break :blk try fs.path.joinZ(util.gpa, &[_][]const u8{ home, ".config/river/init" });
        } else {
            return null;
        }
    };

    os.accessZ(path, os.X_OK) catch |err| {
        std.log.err("failed to run init executable {s}: {s}", .{ path, @errorName(err) });
        util.gpa.free(path);
        return null;
    };

    return path;
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.foobar),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@enumToInt(message_level) <= @enumToInt(level)) {
        // Don't store/log messages in release small mode to save space
        if (std.builtin.mode != .ReleaseSmall) {
            const stderr = io.getStdErr().writer();
            stderr.print(@tagName(message_level) ++ ": (" ++ @tagName(scope) ++ ") " ++
                format ++ "\n", args) catch return;
        }
    }
}
