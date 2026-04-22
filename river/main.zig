// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const build_options = @import("build_options");
const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const Io = std.Io;
const log = std.log;
const posix = std.posix;
const exit = std.process.exit;

const builtin = @import("builtin");
const wlr = @import("wlroots");
const flags = @import("flags");

const util = @import("util.zig");
const process = @import("process.zig");

const Server = @import("Server.zig");

const io = Io.Threaded.global_single_threaded.io();

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

const full_version = std.fmt.comptimePrint("{s} {c}xwayland", .{
    build_options.version,
    if (build_options.xwayland) '+' else '-',
});

pub var server: Server = undefined;

pub fn main(init: std.process.Init.Minimal) anyerror!void {
    var arena_alloc = std.heap.ArenaAllocator.init(util.gpa);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const args = try init.args.toSlice(arena);

    const result = flags.parser(&.{
        .{ .name = "h", .kind = .boolean },
        .{ .name = "version", .kind = .boolean },
        .{ .name = "c", .kind = .arg },
        .{ .name = "log-level", .kind = .arg },
        .{ .name = "log-scopes", .kind = .arg },
        .{ .name = "no-xwayland", .kind = .boolean },
    }).parse(args[1..]) catch {
        try stderr.writeAll(usage);
        try stderr.flush();
        exit(1);
    };
    if (result.flags.h) {
        try stdout.writeAll(usage);
        try stdout.flush();
        exit(0);
    }
    if (result.args.len != 0) {
        log.err("unknown option '{s}'", .{result.args[0]});
        try stderr.writeAll(usage);
        try stderr.flush();
        exit(1);
    }

    if (result.flags.version) {
        try stdout.writeAll(full_version ++ "\n");
        try stdout.flush();
        exit(0);
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
            exit(1);
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
                    exit(1);
                };
                log_scopes.remove(scope);
            } else {
                const scope = std.meta.stringToEnum(LogScope, raw) orelse {
                    log.err("invalid log scope '{s}'", .{raw});
                    exit(1);
                };
                log_scopes.insert(scope);
            }
        }
    }
    const runtime_xwayland = !result.flags.@"no-xwayland";
    const startup_command = blk: {
        if (result.flags.c) |command| {
            break :blk try util.gpa.dupeZ(u8, command);
        } else {
            break :blk try defaultInitPath(init.environ);
        }
    };
    defer if (startup_command) |cmd| util.gpa.free(cmd);

    try detectClassic(startup_command);

    log.info("initializing river version {s}", .{full_version});
    if (build_options.xwayland and !runtime_xwayland) {
        log.info("Xwayland disabled at runtime with -no-xwayland", .{});
    }

    river_init_wlroots_log(switch (runtime_log_level) {
        .debug => .debug,
        .info => .info,
        .warn, .err => .err,
    });

    try server.init(runtime_xwayland);
    defer server.deinit();

    // wlroots starts the Xwayland process from an idle event source, the reasoning being that
    // this gives the compositor time to set up event listeners before Xwayland is actually
    // started. We want Xwayland to be started by wlroots before we modify our rlimits in
    // process.setup() since wlroots does not offer a way for us to reset the rlimit post-fork.
    if (build_options.xwayland and runtime_xwayland) {
        server.wl_server.getEventLoop().dispatchIdle();
    }

    process.setup();

    var buf: [11]u8 = undefined;
    const socket = try server.wl_server.addSocketAuto(&buf);
    try server.backend.start();

    // Run the child in a new process group so that we can send SIGTERM to all
    // descendants on exit.
    const child_pgid = if (startup_command) |cmd| blk: {
        log.info("running init executable '{s}'", .{cmd});

        var env_map = try init.environ.createMap(util.gpa);
        defer env_map.deinit();

        try env_map.put("WAYLAND_DISPLAY", socket);

        if (build_options.xwayland) {
            if (server.xwayland) |xwayland| {
                try env_map.put("DISPLAY", mem.sliceTo(xwayland.display_name, 0));
            }
        }

        const env_block = try env_map.createPosixBlock(util.gpa, .{});
        defer env_block.deinit(util.gpa);

        const child_args = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd, null };

        const pid: posix.pid_t = fork: {
            const rc = posix.system.fork();
            switch (posix.errno(rc)) {
                .SUCCESS => break :fork @intCast(rc),
                .AGAIN => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .NOSYS => return error.OperationUnsupported,
                else => |err| return posix.unexpectedErrno(err),
            }
        };

        if (pid == 0) {
            process.cleanupChild();
            if (posix.errno(posix.system.execve("/bin/sh", &child_args, env_block.slice.ptr)) != .SUCCESS) {
                posix.system.exit(1);
            }
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
}

fn defaultInitPath(environ: std.process.Environ) !?[:0]const u8 {
    const path = blk: {
        if (environ.getPosix("XDG_CONFIG_HOME")) |xdg_config_home| {
            break :blk try fs.path.joinZ(util.gpa, &[_][]const u8{ xdg_config_home, "river/init" });
        } else if (environ.getPosix("HOME")) |home| {
            break :blk try fs.path.joinZ(util.gpa, &[_][]const u8{ home, ".config/river/init" });
        } else {
            return null;
        }
    };

    Io.Dir.cwd().access(io, path, .{ .execute = true }) catch |err| {
        if (err == error.PermissionDenied) {
            if (Io.Dir.cwd().access(io, path, .{})) {
                log.err("failed to run init executable {s}: the file is not executable", .{path});
                exit(1);
            } else |_| {}
        }
        log.err("failed to run init executable {s}: {s}", .{ path, @errorName(err) });
        util.gpa.free(path);
        return null;
    };

    return path;
}

fn detectClassic(startup_command: ?[:0]const u8) !void {
    const path = startup_command orelse return;
    if (mem.indexOfScalar(u8, path, '/') == null) return;

    const classic = grepRiverctl(path) catch |err| {
        log.debug("failed to detect riverctl usage in init file: {s}", .{@errorName(err)});
        return;
    };
    if (classic) {
        try stderr.print(
            \\The init file {[path]s} contains the string "riverctl".
            \\This river version ({[version]s}) does not support riverctl, you may
            \\wish to install river-classic instead.
            \\
            \\River {[version]s} is a non-monolithic Wayland compositor and
            \\requires a compatible window manager to be useful.
            \\See https://isaacfreund.com/software/river for more information.
            \\
        , .{
            .path = path,
            .version = build_options.version,
        });
        try stderr.flush();
        exit(1);
    }
}

fn grepRiverctl(path: [:0]const u8) !bool {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [1024]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    const reader = &file_reader.interface;
    while (true) {
        _ = try reader.discardDelimiterExclusive('r');
        const bytes = reader.peekArray("riverctl".len) catch |err| switch (err) {
            error.EndOfStream => return false,
            else => |e| return e,
        };
        if (mem.eql(u8, bytes, "riverctl")) {
            return true;
        }
        reader.toss(1);
    }
}

var stderr_buffer: [1024]u8 = undefined;
var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
const stderr = &stderr_writer.interface;

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
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
