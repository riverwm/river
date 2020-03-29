const std = @import("std");

pub const Log = enum {
    const Self = @This();

    Silent,
    Error,
    Info,
    Debug,

    var verbosity = Self.Error;

    pub fn init(_verbosity: Self) void {
        verbosity = _verbosity;
    }

    fn log(level: Self, comptime format: []const u8, args: var) void {
        if (@enumToInt(level) <= @enumToInt(verbosity)) {
            // TODO: log the time since start in the same format as wlroots
            // TODO: use color if logging to a tty
            std.debug.warn("[{}] " ++ format ++ "\n", .{@tagName(level)} ++ args);
        }
    }
};
