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
const mem = std.mem;
const cstr = std.cstr;

const root = @import("root");

pub const FlagDef = struct {
    name: [*:0]const u8,
    kind: enum { boolean, arg },
};

pub fn Args(comptime num_positionals: comptime_int, comptime flag_defs: []const FlagDef) type {
    return struct {
        const Self = @This();

        positionals: [num_positionals][*:0]const u8,
        flags: [flag_defs.len]struct {
            name: [*:0]const u8,
            value: union {
                boolean: bool,
                arg: ?[*:0]const u8,
            },
        },

        pub fn parse(argv: [][*:0]const u8) Self {
            var ret: Self = undefined;

            // Init all flags in the flags array to false/null
            inline for (flag_defs) |flag_def, flag_idx| {
                switch (flag_def.kind) {
                    .boolean => ret.flags[flag_idx] = .{
                        .name = flag_def.name,
                        .value = .{ .boolean = false },
                    },
                    .arg => ret.flags[flag_idx] = .{
                        .name = flag_def.name,
                        .value = .{ .arg = null },
                    },
                }
            }

            // Parse the argv in to the positionals and flags arrays
            var arg_idx: usize = 0;
            var positional_idx: usize = 0;
            outer: while (arg_idx < argv.len) : (arg_idx += 1) {
                var should_continue = false;
                inline for (flag_defs) |flag_def, flag_idx| {
                    if (cstr.cmp(flag_def.name, argv[arg_idx]) == 0) {
                        switch (flag_def.kind) {
                            .boolean => ret.flags[flag_idx].value.boolean = true,
                            .arg => {
                                arg_idx += 1;
                                ret.flags[flag_idx].value.arg = if (arg_idx < argv.len)
                                    argv[arg_idx]
                                else
                                    root.fatal("flag '" ++ flag_def.name ++
                                        "' requires an argument but none was provided!", .{});
                            },
                        }
                        // TODO: this variable exists as a workaround for the fact that
                        // using continue :outer here crashes the stage1 compiler.
                        should_continue = true;
                    }
                }
                if (should_continue) continue;

                if (positional_idx == num_positionals) {
                    root.fatal(
                        "{} positional arguments expected but more were provided!",
                        .{num_positionals},
                    );
                }

                // This check should not be needed as this code is unreachable
                // if num_positionals is 0. Howevere the stage1 zig compiler does
                // not seem to be smart enough to realize this.
                if (num_positionals > 0) {
                    ret.positionals[positional_idx] = argv[arg_idx];
                } else {
                    unreachable;
                }
                positional_idx += 1;
            }

            if (positional_idx < num_positionals) {
                root.fatal(
                    "{} positional arguments expected but only {} were provided!",
                    .{ num_positionals, positional_idx },
                );
            }

            return ret;
        }

        pub fn boolFlag(self: Self, flag_name: [*:0]const u8) bool {
            for (self.flags) |flag| {
                if (cstr.cmp(flag.name, flag_name) == 0) return flag.value.boolean;
            }
            unreachable;
        }

        pub fn argFlag(self: Self, flag_name: [*:0]const u8) ?[*:0]const u8 {
            for (self.flags) |flag| {
                if (cstr.cmp(flag.name, flag_name) == 0) return flag.value.arg;
            }
            unreachable;
        }
    };
}
