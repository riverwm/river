// Zero allocation argument parsing for unix-like systems.
// Released under the Zero Clause BSD (0BSD) license:
//
// Copyright 2023 Isaac Freund
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

const std = @import("std");
const mem = std.mem;

pub const Flag = struct {
    name: [:0]const u8,
    kind: enum { boolean, arg },
};

pub fn parser(comptime Arg: type, comptime flags: []const Flag) type {
    switch (Arg) {
        // TODO consider allowing []const u8
        [:0]const u8, [*:0]const u8 => {}, // ok
        else => @compileError("invalid argument type: " ++ @typeName(Arg)),
    }
    return struct {
        pub const Result = struct {
            /// Remaining args after the recognized flags
            args: []const Arg,
            /// Data obtained from parsed flags
            flags: Flags,

            pub const Flags = flags_type: {
                var fields: []const std.builtin.Type.StructField = &.{};
                for (flags) |flag| {
                    const field: std.builtin.Type.StructField = switch (flag.kind) {
                        .boolean => .{
                            .name = flag.name,
                            .type = bool,
                            .default_value = &false,
                            .is_comptime = false,
                            .alignment = @alignOf(bool),
                        },
                        .arg => .{
                            .name = flag.name,
                            .type = ?[:0]const u8,
                            .default_value = &@as(?[:0]const u8, null),
                            .is_comptime = false,
                            .alignment = @alignOf(?[:0]const u8),
                        },
                    };
                    fields = fields ++ [_]std.builtin.Type.StructField{field};
                }
                break :flags_type @Type(.{ .Struct = .{
                    .layout = .auto,
                    .fields = fields,
                    .decls = &.{},
                    .is_tuple = false,
                } });
            };
        };

        pub fn parse(args: []const Arg) !Result {
            var result_flags: Result.Flags = .{};

            var i: usize = 0;
            outer: while (i < args.len) : (i += 1) {
                const arg = switch (Arg) {
                    [*:0]const u8 => mem.sliceTo(args[i], 0),
                    [:0]const u8 => args[i],
                    else => unreachable,
                };
                inline for (flags) |flag| {
                    if (mem.eql(u8, "-" ++ flag.name, arg)) {
                        switch (flag.kind) {
                            .boolean => @field(result_flags, flag.name) = true,
                            .arg => {
                                i += 1;
                                if (i == args.len) {
                                    std.log.err("option '-" ++ flag.name ++
                                        "' requires an argument but none was provided!", .{});
                                    return error.MissingFlagArgument;
                                }
                                @field(result_flags, flag.name) = switch (Arg) {
                                    [*:0]const u8 => mem.sliceTo(args[i], 0),
                                    [:0]const u8 => args[i],
                                    else => unreachable,
                                };
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
