// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 The River Developers
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
const cstr = std.cstr;

pub const Flag = struct {
    name: [*:0]const u8,
    kind: enum { boolean, arg },
};

pub fn ParseResult(comptime flags: []const Flag) type {
    return struct {
        const Self = @This();

        const FlagData = struct {
            name: [*:0]const u8,
            value: union {
                boolean: bool,
                arg: ?[*:0]const u8,
            },
        };

        /// Remaining args after the recognized flags
        args: [][*:0]const u8,
        /// Data obtained from parsed flags
        flag_data: [flags.len]FlagData = blk: {
            // Init all flags to false/null
            var flag_data: [flags.len]FlagData = undefined;
            inline for (flags) |flag, i| {
                flag_data[i] = switch (flag.kind) {
                    .boolean => .{
                        .name = flag.name,
                        .value = .{ .boolean = false },
                    },
                    .arg => .{
                        .name = flag.name,
                        .value = .{ .arg = null },
                    },
                };
            }
            break :blk flag_data;
        },

        pub fn boolFlag(self: Self, flag_name: [*:0]const u8) bool {
            for (self.flag_data) |flag_data| {
                if (cstr.cmp(flag_data.name, flag_name) == 0) return flag_data.value.boolean;
            }
            unreachable; // Invalid flag_name
        }

        pub fn argFlag(self: Self, flag_name: [*:0]const u8) ?[*:0]const u8 {
            for (self.flag_data) |flag_data| {
                if (cstr.cmp(flag_data.name, flag_name) == 0) return flag_data.value.arg;
            }
            unreachable; // Invalid flag_name
        }
    };
}

pub fn parse(args: [][*:0]const u8, comptime flags: []const Flag) !ParseResult(flags) {
    var ret: ParseResult(flags) = .{ .args = undefined };

    var arg_idx: usize = 0;
    while (arg_idx < args.len) : (arg_idx += 1) {
        var parsed_flag = false;
        inline for (flags) |flag, flag_idx| {
            if (cstr.cmp(flag.name, args[arg_idx]) == 0) {
                switch (flag.kind) {
                    .boolean => ret.flag_data[flag_idx].value.boolean = true,
                    .arg => {
                        arg_idx += 1;
                        if (arg_idx == args.len) {
                            std.log.err("option '" ++ flag.name ++
                                "' requires an argument but none was provided!", .{});
                            return error.MissingFlagArgument;
                        }
                        ret.flag_data[flag_idx].value.arg = args[arg_idx];
                    },
                }
                parsed_flag = true;
            }
        }
        if (!parsed_flag) break;
    }

    ret.args = args[arg_idx..];

    return ret;
}
