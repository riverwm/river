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
const flags = @import("flags");

const c = @import("c.zig");
const util = @import("util.zig");

const Server = @import("Server.zig");

const usage: []const u8 =
    \\usage: river [options]
    \\
    \\  -help              Print this help message and exit.
    \\  -version           Print the version number and exit.
    \\  -c <command>       Run `sh -c <command>` on startup.
    \\  -log-level <level> Set the log level to error, warning, info, or debug.
    \\
;

pub var server: Server = undefined;

pub fn main() anyerror!void {
    // This line is here because of https://github.com/ziglang/zig/issues/7807
    const argv: [][*:0]const u8 = os.argv;
    const result = flags.parse(argv[1..], &[_]flags.Flag{
        .{ .name = "-help", .kind = .boolean },
        .{ .name = "-version", .kind = .boolean },
        .{ .name = "-c", .kind = .arg },
        .{ .name = "-log-level", .kind = .arg },
    }) catch {
        try io.getStdErr().writeAll(usage);
        os.exit(1);
    };
    if (result.boolFlag("-help")) {
        try io.getStdOut().writeAll(usage);
        os.exit(0);
    }
    if (result.args.len != 0) {
        std.log.err("unknown option '{s}'", .{result.args[0]});
        try io.getStdErr().writeAll(usage);
        os.exit(1);
    }

    if (result.boolFlag("-version")) {
        try io.getStdOut().writeAll(build_options.version);
        os.exit(0);
    }
    if (result.argFlag("-log-level")) |level_str| {
        const level = std.meta.stringToEnum(LogLevel, std.mem.span(level_str)) orelse {
            std.log.err("invalid log level '{s}'", .{level_str});
            try io.getStdErr().writeAll(usage);
            os.exit(1);
        };
        runtime_log_level = switch (level) {
            .@"error" => .err,
            .warning => .warn,
            .info => .info,
            .debug => .debug,
        };
    }
    const startup_command = blk: {
        if (result.argFlag("-c")) |command| {
            break :blk try util.gpa.dupeZ(u8, std.mem.span(command));
        } else {
            break :blk try defaultInitPath();
        }
    };

    river_init_wlroots_log(switch (runtime_log_level) {
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

/// Tell std.log to leave all log level filtering to us.
pub const log_level: std.log.Level = .debug;

/// Set the default log level based on the build mode.
var runtime_log_level: std.log.Level = switch (std.builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .info,
};

/// River only exposes these 4 log levels to the user for simplicity
const LogLevel = enum {
    @"error",
    warning,
    info,
    debug,
};

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@enumToInt(message_level) > @enumToInt(runtime_log_level)) return;

    const river_level: LogLevel = switch (message_level) {
        .emerg, .alert, .crit, .err => .@"error",
        .warn => .warning,
        .notice, .info => .info,
        .debug => .debug,
    };
    const scope_prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    const stderr = std.io.getStdErr().writer();
    stderr.print(@tagName(river_level) ++ scope_prefix ++ format ++ "\n", args) catch {};
}

/// See wlroots_log_wrapper.c
extern fn river_init_wlroots_log(importance: wlr.log.Importance) void;
export fn river_wlroots_log_callback(importance: wlr.log.Importance, ptr: [*:0]const u8, len: usize) void {
    switch (importance) {
        .err => log(.err, .wlroots, "{s}", .{ptr[0..len]}),
        .info => log(.info, .wlroots, "{s}", .{ptr[0..len]}),
        .debug => log(.debug, .wlroots, "{s}", .{ptr[0..len]}),
        .silent, .last => unreachable,
    }
}
