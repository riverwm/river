// SPDX-FileCopyrightText: © 2022 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

/// The global general-purpose allocator used throughout river's code
pub const gpa = std.heap.c_allocator;

pub fn msecTimestamp() u32 {
    const now = std.posix.clock_gettime(.MONOTONIC) catch @panic("CLOCK_MONOTONIC not supported");
    // 2^32-1 milliseconds is ~50 days, which is a realistic uptime.
    // This means that we must wrap if the monotonic time is greater than
    // 2^32-1 milliseconds and hope that clients don't get too confused.
    return @intCast(@rem(
        now.sec *% std.time.ms_per_s +% @divTrunc(now.nsec, std.time.ns_per_ms),
        std.math.maxInt(u32),
    ));
}
