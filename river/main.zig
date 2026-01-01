// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const build_options = @import("build_options");
const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const io = std.io;
const log = std.log;
const posix = std.posix;
const builtin = @import("builtin");
const wlr = @import("wlroots");
const flags = @import("flags");

const c = @import("c.zig").c;
const util = @import("util.zig");
const process = @import("process.zig");

const Server = @import("Server.zig");

const usage: []const u8 =
    \\usage: river [options]
    \\
    \\  -h                 Print this help message and exit.
    \\  -version           Print the version number and exit.
    \\  -c <command>       Run `sh -c <command>` on startup instead of the default init executable.
    \\  -log-level <level> Set the log level to error, warning, info, or debug.
    \\  -no-xwayland       Disable xwayland even if built with support.
    \\
;

pub var server: Server = undefined;

pub fn main() anyerror!void {
    const result = flags.parser([*:0]const u8, &.{
        .{ .name = "h", .kind = .boolean },
        .{ .name = "version", .kind = .boolean },
        .{ .name = "c", .kind = .arg },
        .{ .name = "log-level", .kind = .arg },
        .{ .name = "log-scopes", .kind = .arg },
        .{ .name = "no-xwayland", .kind = .boolean },
    }).parse(std.os.argv[1..]) catch {
        try stderr.writeAll(usage);
        try stderr.flush();
        posix.exit(1);
    };
    if (result.flags.h) {
        try stdout.writeAll(usage);
        try stdout.flush();
        posix.exit(0);
    }
    if (result.args.len != 0) {
        log.err("unknown option '{s}'", .{result.args[0]});
        try stderr.writeAll(usage);
        try stderr.flush();
        posix.exit(1);
    }

    if (result.flags.version) {
        try stdout.writeAll(build_options.version ++ "\n");
        try stdout.flush();
        posix.exit(0);
    }
    if (result.flags.@"log-level") |level| {
        if (mem.eql(u8, level, "error")) {
            runtime_log_level = .err;
        } else if (mem.eql(u8, level, "warning")) {
            runtime_log_level = .warn;
        } else if (mem.eql(u8, level, "info")) {
            runtime_log_level = .info;
        } else if (mem.eql(u8, level, "debug")) {
            runtime_log_level = .debug;
        } else {
            log.err("invalid log level '{s}'", .{level});
            posix.exit(1);
        }
    }
    if (result.flags.@"log-scopes") |scopes| {
        // Examples:
        // -log-scopes input,wm     (only default, input, and wm scopes)
        // -log-scopes all,~wlroots (all scopes except wlroots)
        log_scopes = std.EnumSet(LogScope).initEmpty();
        var it = mem.splitScalar(u8, scopes, ',');
        while (it.next()) |raw| {
            if (mem.eql(u8, raw, "all")) {
                log_scopes = std.EnumSet(LogScope).initFull();
            } else if (raw.len > 0 and raw[0] == '~') {
                // I'd rather use an exclamation mark than a tilde but the
                // former requires quoting in most shells.
                const scope = std.meta.stringToEnum(LogScope, raw[1..]) orelse {
                    log.err("invalid log scope '{s}'", .{raw});
                    posix.exit(1);
                };
                log_scopes.remove(scope);
            } else {
                const scope = std.meta.stringToEnum(LogScope, raw) orelse {
                    log.err("invalid log scope '{s}'", .{raw});
                    posix.exit(1);
                };
                log_scopes.insert(scope);
            }
        }
    }
    const enable_xwayland = !result.flags.@"no-xwayland";
    const startup_command = blk: {
        if (result.flags.c) |command| {
            break :blk try util.gpa.dupeZ(u8, command);
        } else {
            break :blk try defaultInitPath();
        }
    };

    log.info("river version {s}, initializing server", .{build_options.version});

    process.setup();

    river_init_wlroots_log(switch (runtime_log_level) {
        .debug => .debug,
        .info => .info,
        .warn, .err => .err,
    });

    try server.init(enable_xwayland);
    defer server.deinit();

    try server.start();

    // Run the child in a new process group so that we can send SIGTERM to all
    // descendants on exit.
    const child_pgid = if (startup_command) |cmd| blk: {
        log.info("running init executable '{s}'", .{cmd});
        const child_args = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd, null };
        const pid = try posix.fork();
        if (pid == 0) {
            process.cleanupChild();
            posix.execveZ("/bin/sh", &child_args, std.c.environ) catch c._exit(1);
        }
        util.gpa.free(cmd);
        // Since the child has called setsid, the pid is the pgid
        break :blk pid;
    } else null;
    defer if (child_pgid) |pgid| posix.kill(-pgid, posix.SIG.TERM) catch |err| {
        log.err("failed to kill init process group: {s}", .{@errorName(err)});
    };

    log.info("running server", .{});

    server.wl_server.run();

    log.info("shutting down", .{});
}

fn defaultInitPath() !?[:0]const u8 {
    const path = blk: {
        if (posix.getenv("XDG_CONFIG_HOME")) |xdg_config_home| {
            break :blk try fs.path.joinZ(util.gpa, &[_][]const u8{ xdg_config_home, "river/init" });
        } else if (posix.getenv("HOME")) |home| {
            break :blk try fs.path.joinZ(util.gpa, &[_][]const u8{ home, ".config/river/init" });
        } else {
            return null;
        }
    };

    posix.accessZ(path, posix.X_OK) catch |err| {
        if (err == error.PermissionDenied) {
            if (posix.accessZ(path, posix.R_OK)) {
                log.err("failed to run init executable {s}: the file is not executable", .{path});
                posix.exit(1);
            } else |_| {}
        }
        log.err("failed to run init executable {s}: {s}", .{ path, @errorName(err) });
        util.gpa.free(path);
        return null;
    };

    return path;
}

var stderr_buffer: [1024]u8 = undefined;
var stderr_writer = fs.File.stderr().writer(&stderr_buffer);
const stderr = &stderr_writer.interface;

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

// Scopes should be added to this list sparingly.
// Only add new scopes if filtering based on them would be meaningful.
const LogScope = enum {
    default,
    wlroots,
    output,
    input,
    lock,
    wm,
    xdg,
    xwayland,
};

var log_scopes: std.EnumSet(LogScope) = std.EnumSet(LogScope).initFull();

/// Set the default log level based on the build mode.
var runtime_log_level: log.Level = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .info,
};

pub const std_options: std.Options = .{
    // Tell std.log to leave all log level filtering to us.
    .log_level = .debug,
    .logFn = logFn,
};

pub fn logFn(
    comptime level: log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(runtime_log_level)) return;

    if (scope != .default and !log_scopes.contains(scope)) return;

    const scope_prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    stderr.print(level.asText() ++ scope_prefix ++ format ++ "\n", args) catch return;
    stderr.flush() catch return;
}

/// See wlroots_log_wrapper.c
extern fn river_init_wlroots_log(importance: wlr.log.Importance) void;
export fn river_wlroots_log_callback(importance: wlr.log.Importance, ptr: [*:0]const u8, len: usize) void {
    const wlr_log = log.scoped(.wlroots);
    switch (importance) {
        .err => wlr_log.err("{s}", .{ptr[0..len]}),
        .info => wlr_log.info("{s}", .{ptr[0..len]}),
        .debug => wlr_log.debug("{s}", .{ptr[0..len]}),
        .silent, .last => unreachable,
    }
}
