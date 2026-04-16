// SPDX-FileCopyrightText: © 2023 Isaac Freund
// SPDX-License-Identifier: 0BSD

const std = @import("std");
const mem = std.mem;

pub const Flag = struct {
    name: []const u8,
    kind: enum { boolean, arg },
};

pub fn parser(comptime flags: []const Flag) type {
    return struct {
        pub const Result = struct {
            /// Remaining args after the recognized flags
            args: []const [:0]const u8,
            /// Data obtained from parsed flags
            flags: Flags,

            pub const Flags = flags_type: {
                const Attributes = std.builtin.Type.StructField.Attributes;
                var names: [flags.len][]const u8 = undefined;
                var types: [flags.len]type = undefined;
                var attrs: [flags.len]Attributes = undefined;
                for (flags, &names, &types, &attrs) |flag, *name, *ty, *attr| {
                    name.* = flag.name;
                    switch (flag.kind) {
                        .boolean => {
                            ty.* = bool;
                            attr.* = .{ .default_value_ptr = &false };
                        },
                        .arg => {
                            ty.* = ?[:0]const u8;
                            attr.* = .{ .default_value_ptr = &@as(ty.*, null) };
                        },
                    }
                }
                break :flags_type @Struct(.auto, null, &names, &types, &attrs);
            };
        };

        pub fn parse(args: []const [:0]const u8) error{MissingFlagArgument}!Result {
            var result_flags: Result.Flags = .{};

            var i: usize = 0;
            outer: while (i < args.len) : (i += 1) {
                inline for (flags) |flag| {
                    if (mem.eql(u8, "-" ++ flag.name, args[i])) {
                        switch (flag.kind) {
                            .boolean => @field(result_flags, flag.name) = true,
                            .arg => {
                                i += 1;
                                if (i == args.len) {
                                    std.log.err("option '-" ++ flag.name ++
                                        "' requires an argument but none was provided!", .{});
                                    return error.MissingFlagArgument;
                                }
                                @field(result_flags, flag.name) = args[i];
                            },
                        }
                        continue :outer;
                    }
                }
                break;
            }

            return Result{
                .args = args[i..],
                .flags = result_flags,
            };
        }
    };
}
