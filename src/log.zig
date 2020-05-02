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

pub const Log = enum {
    const Self = @This();

    Silent = 0,
    Error = 1,
    Info = 2,
    Debug = 3,

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
