const c = @import("../c.zig");
const std = @import("std");

const Arg = @import("../command.zig").Arg;
const Log = @import("../log.zig").Log;
const Seat = @import("../seat.zig");

/// Spawn a program.
pub fn spawn(seat: *Seat, arg: Arg) void {
    const cmd = arg.str;

    const argv = [_][]const u8{ "/bin/sh", "-c", cmd };
    const child = std.ChildProcess.init(&argv, std.heap.c_allocator) catch |err| {
        Log.Error.log("Failed to execute {}: {}", .{ cmd, err });
        return;
    };
    std.ChildProcess.spawn(child) catch |err| {
        Log.Error.log("Failed to execute {}: {}", .{ cmd, err });
        return;
    };
}
