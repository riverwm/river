// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
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

pub const Level = enum {
    /// Emergency: a condition that cannot be handled, usually followed by a
    /// panic.
    emerg,
    /// Alert: a condition that should be corrected immediately (e.g. database
    /// corruption).
    alert,
    /// Critical: A bug has been detected or something has gone wrong and it
    /// will have an effect on the operation of the program.
    crit,
    /// Error: A bug has been detected or something has gone wrong but it is
    /// recoverable.
    err,
    /// Warning: it is uncertain if something has gone wrong or not, but the
    /// circumstances would be worth investigating.
    warn,
    /// Notice: non-error but significant conditions.
    notice,
    /// Informational: general messages about the state of the program.
    info,
    /// Debug: messages only useful for debugging.
    debug,
};

/// The default log level is based on build mode. Note that in ReleaseSmall
/// builds the default level is emerg but no messages will be stored/logged
/// to save space.
pub var level: Level = switch (std.builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe => .notice,
    .ReleaseFast => .err,
    .ReleaseSmall => .emerg,
};

fn log(
    comptime message_level: Level,
    comptime scope: @TypeOf(.foobar),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@enumToInt(message_level) <= @enumToInt(level)) {
        // Don't store/log messages in release small mode to save space
        if (std.builtin.mode != .ReleaseSmall) {
            const stderr = std.io.getStdErr().writer();
            stderr.print(@tagName(message_level) ++ ": (" ++ @tagName(scope) ++ ") " ++
                format ++ "\n", args) catch return;
        }
    }
}

/// Log an emergency message to stderr. This log level is intended to be used
/// for conditions that cannot be handled and is usually followed by a panic.
pub fn emerg(
    comptime scope: @TypeOf(.foobar),
    comptime format: []const u8,
    args: anytype,
) void {
    @setCold(true);
    log(.emerg, scope, format, args);
}

/// Log an alert message to stderr. This log level is intended to be used for
/// conditions that should be corrected immediately (e.g. database corruption).
pub fn alert(
    comptime scope: @TypeOf(.foobar),
    comptime format: []const u8,
    args: anytype,
) void {
    @setCold(true);
    log(.alert, scope, format, args);
}

/// Log a critical message to stderr. This log level is intended to be used
/// when a bug has been detected or something has gone wrong and it will have
/// an effect on the operation of the program.
pub fn crit(
    comptime scope: @TypeOf(.foobar),
    comptime format: []const u8,
    args: anytype,
) void {
    @setCold(true);
    log(.crit, scope, format, args);
}

/// Log an error message to stderr. This log level is intended to be used when
/// a bug has been detected or something has gone wrong but it is recoverable.
pub fn err(
    comptime scope: @TypeOf(.foobar),
    comptime format: []const u8,
    args: anytype,
) void {
    @setCold(true);
    log(.err, scope, format, args);
}

/// Log a warning message to stderr. This log level is intended to be used if
/// it is uncertain whether something has gone wrong or not, but the
/// circumstances would be worth investigating.
pub fn warn(
    comptime scope: @TypeOf(.foobar),
    comptime format: []const u8,
    args: anytype,
) void {
    log(.warn, scope, format, args);
}

/// Log a notice message to stderr. This log level is intended to be used for
/// non-error but significant conditions.
pub fn notice(
    comptime scope: @TypeOf(.foobar),
    comptime format: []const u8,
    args: anytype,
) void {
    log(.notice, scope, format, args);
}

/// Log an info message to stderr. This log level is intended to be used for
/// general messages about the state of the program.
pub fn info(
    comptime scope: @TypeOf(.foobar),
    comptime format: []const u8,
    args: anytype,
) void {
    log(.info, scope, format, args);
}

/// Log a debug message to stderr. This log level is intended to be used for
/// messages which are only useful for debugging.
pub fn debug(
    comptime scope: @TypeOf(.foobar),
    comptime format: []const u8,
    args: anytype,
) void {
    log(.debug, scope, format, args);
}
