// SPDX-FileCopyrightText: © 2022 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const posix = std.posix;
const wlr = @import("wlroots");

const server = &@import("main.zig").server;

/// The global general-purpose allocator used throughout river's code
pub const gpa = std.heap.c_allocator;

pub fn timestamp() posix.timespec {
    var timespec: posix.timespec = undefined;
    switch (posix.errno(posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &timespec))) {
        .SUCCESS => return timespec,
        else => @panic("CLOCK_MONOTONIC not supported"),
    }
}

pub fn msecTimestamp() u32 {
    const now = timestamp();
    // 2^32-1 milliseconds is ~50 days, which is a realistic uptime.
    // This means that we must wrap if the monotonic time is greater than
    // 2^32-1 milliseconds and hope that clients don't get too confused.
    return @intCast(@rem(
        now.sec *% std.time.ms_per_s +% @divTrunc(now.nsec, std.time.ns_per_ms),
        std.math.maxInt(u32),
    ));
}

/// Converts absolute coordinates in range 0.0 - 1.0 into output layout coordinates.
pub fn absoluteToLayout(mapping: wlr.Box, abs_x: f64, abs_y: f64) struct { f64, f64 } {
    var m = mapping;
    if (m.empty()) {
        server.om.output_layout.getBox(null, &m);
    }
    return .{
        @as(f64, @floatFromInt(m.x)) + @as(f64, @floatFromInt(m.width)) * abs_x,
        @as(f64, @floatFromInt(m.y)) + @as(f64, @floatFromInt(m.height)) * abs_y,
    };
}
