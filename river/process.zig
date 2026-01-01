// SPDX-FileCopyrightText: © 2022 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const posix = std.posix;

const c = @import("c.zig").c;

var original_rlimit: ?posix.rlimit = null;

pub fn setup() void {
    // Ignore SIGPIPE so we don't get killed when writing to a socket that
    // has had its read end closed by another process.
    const sig_ign = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &sig_ign, null);

    // Most unix systems have a default limit of 1024 file descriptors and it
    // seems unlikely for this default to be universally raised due to the
    // broken behavior of select() on fds with value >1024. However, it is
    // unreasonable to use such a low limit for a process such as river which
    // uses many fds in its communication with wayland clients and the kernel.
    //
    // There is however an advantage to having a relatively low limit: it helps
    // to catch any fd leaks. Therefore, don't use some crazy high limit that
    // can never be reached before the system runs out of memory. This can be
    // raised further if anyone reaches it in practice.
    if (posix.getrlimit(.NOFILE)) |original| {
        original_rlimit = original;
        const new: posix.rlimit = .{
            .cur = @min(4096, original.max),
            .max = original.max,
        };
        if (posix.setrlimit(.NOFILE, new)) {
            std.log.info("raised file descriptor limit of the river process to {d}", .{new.cur});
        } else |_| {
            std.log.err("setrlimit failed, using system default file descriptor limit of {d}", .{
                original.cur,
            });
        }
    } else |_| {
        std.log.err("getrlimit failed, using system default file descriptor limit ", .{});
    }
}

pub fn cleanupChild() void {
    if (c.setsid() < 0) unreachable;
    if (posix.system.sigprocmask(posix.SIG.SETMASK, &posix.sigemptyset(), null) < 0) unreachable;

    const sig_dfl = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &sig_dfl, null);

    if (original_rlimit) |original| {
        posix.setrlimit(.NOFILE, original) catch {
            std.log.err("failed to restore original file descriptor limit for " ++
                "child process, setrlimit failed", .{});
        };
    }
}
