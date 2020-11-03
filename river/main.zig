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
const wlr = @import("wlroots");

const c = @import("c.zig");
const log = @import("log.zig");
const util = @import("util.zig");

const Server = @import("Server.zig");

const usage: []const u8 =
    \\Usage: river [options]
    \\
    \\  -h            Print this help message and exit.
    \\  -c <command>  Run `sh -c <command>` on startup.
    \\  -l <level>    Set the log level to a value from 0 to 7.
    \\
;

fn testConfigPath(comptime fmt: []const u8, args: anytype) std.fmt.AllocPrintError!?[:0]const u8 {
    const path = try std.fmt.allocPrintZ(util.gpa, fmt, args);
    std.os.access(path, std.os.X_OK) catch {
        util.gpa.free(path);
        return null;
    };
    return path;
}

fn getStartupCommand() std.fmt.AllocPrintError!?[:0]const u8 {
    if (std.os.getenv("XDG_CONFIG_HOME")) |xdg_config_home| {
        if (try testConfigPath("{}/river/init", .{xdg_config_home})) |path| {
            return path;
        }
    } else if (std.os.getenv("HOME")) |home| {
        if (try testConfigPath("{}/.config/river/init", .{home})) |path| {
            return path;
        }
    }
    if (try testConfigPath("/etc/river/init", .{})) |path| {
        return path;
    }
    return null;
}

pub fn main() anyerror!void {
    var startup_command: ?[:0]const u8 = null;
    {
        var it = std.process.args();
        // Skip our name
        _ = it.nextPosix();
        while (it.nextPosix()) |arg| {
            if (std.mem.eql(u8, arg, "-h")) {
                const stdout = std.io.getStdOut().outStream();
                try stdout.print(usage, .{});
                std.os.exit(0);
            } else if (std.mem.eql(u8, arg, "-c")) {
                if (it.nextPosix()) |command| {
                    // If the user used '-c' multiple times the variable
                    // already holds a path and needs to be freed.
                    if (startup_command) |ptr| util.gpa.free(ptr);
                    startup_command = try util.gpa.dupeZ(u8, std.mem.spanZ(command.ptr));
                } else {
                    printErrorExit("Error: flag '-c' requires exactly one argument", .{});
                }
            } else if (std.mem.eql(u8, arg, "-l")) {
                if (it.nextPosix()) |level_str| {
                    const level = std.fmt.parseInt(u3, level_str, 10) catch
                        printErrorExit("Error: invalid log level '{}'", .{level_str});
                    log.level = @intToEnum(log.Level, level);
                } else {
                    printErrorExit("Error: flag '-l' requires exactly one argument", .{});
                }
            } else {
                const stderr = std.io.getStdErr().outStream();
                try stderr.print(usage, .{});
                std.os.exit(1);
            }
        }
    }

    wlr.log.init(switch (log.level) {
        .debug => .debug,
        .notice, .info => .info,
        .warn, .err, .crit, .alert, .emerg => .err,
    });

    log.info(.server, "initializing", .{});

    if (startup_command == null) {
        if (try getStartupCommand()) |path| {
            startup_command = path;
            log.info(.server, "Using default startup command path: {}", .{path});
        } else {
            log.info(.server, "Starting without startup command", .{});
        }
    } else {
        log.info(.server, "Using custom startup command path: {}", .{startup_command});
    }

    var server: Server = undefined;
    try server.init();
    defer server.deinit();

    try server.start();

    const child_pid = if (startup_command) |cmd| blk: {
        const child_args = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd, null };
        const pid = try std.os.fork();
        if (pid == 0) {
            if (std.os.system.sigprocmask(std.os.SIG_SETMASK, &std.os.empty_sigset, null) < 0) unreachable;
            std.os.execveZ("/bin/sh", &child_args, std.c.environ) catch c._exit(1);
        }
        util.gpa.free(cmd);
        break :blk pid;
    } else null;
    defer if (child_pid) |pid|
        std.os.kill(pid, std.os.SIGTERM) catch |e| log.err(.server, "failed to kill startup process: {}", .{e});

    log.info(.server, "running...", .{});

    server.wl_server.run();

    log.info(.server, "shutting down", .{});
}

fn printErrorExit(comptime format: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr().outStream();
    stderr.print(format ++ "\n", args) catch std.os.exit(1);
    std.os.exit(1);
}
