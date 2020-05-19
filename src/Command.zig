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

const Self = @This();

const std = @import("std");

const Seat = @import("Seat.zig");

const command = struct {
    const close = @import("command/close.zig").close;
    const exit = @import("command/exit.zig").exit;
    const focus = @import("command/focus.zig").focus;
    const focusAllTags = @import("command/focus_all_tags.zig").focusAllTags;
    const focusOutput = @import("command/focus_output.zig").focusOutput;
    const focusTag = @import("command/focus_tag.zig").focusTag;
    const modMasterCount = @import("command/mod_master_count.zig").modMasterCount;
    const modMasterFactor = @import("command/mod_master_factor.zig").modMasterFactor;
    const mode = @import("command/mode.zig").mode;
    const sendToOutput = @import("command/send_to_output.zig").sendToOutput;
    const spawn = @import("command/spawn.zig").spawn;
    const tagView = @import("command/tag_view.zig").tagView;
    const tagViewAllTags = @import("command/tag_view_all_tags.zig").tagViewAllTags;
    const toggleFloat = @import("command/toggle_float.zig").toggleFloat;
    const toggleTagFocus = @import("command/toggle_tag_focus.zig").toggleTagFocus;
    const toggleViewTag = @import("command/toggle_view_tag.zig").toggleViewTag;
    const zoom = @import("command/zoom.zig").zoom;
};

const Direction = enum {
    Next,
    Prev,
};

pub const Arg = union(enum) {
    int: i32,
    uint: u32,
    float: f64,
    str: []const u8,
    direction: Direction,
    none: void,

    fn parse(
        arg_type: @TagType(Arg),
        args: []const []const u8,
        allocator: *std.mem.Allocator,
    ) !Arg {
        switch (arg_type) {
            .int, .uint, .float, .direction => {
                if (args.len == 0) return error.NotEnoughArguments;
                if (args.len > 1) return error.TooManyArguments;
                return switch (arg_type) {
                    .int => .{ .int = try std.fmt.parseInt(i32, args[0], 10) },
                    .uint => .{ .uint = try std.fmt.parseInt(u32, args[0], 10) },
                    .float => .{ .float = try std.fmt.parseFloat(f64, args[0]) },
                    .direction => if (std.mem.eql(u8, args[0], "next"))
                        Arg{ .direction = .Next }
                    else if (std.mem.eql(u8, args[0], "previous"))
                        Arg{ .direction = .Prev }
                    else
                        error.InvalidDirection,
                    else => unreachable,
                };
            },
            .str => {
                if (args.len == 0) return error.NotEnoughArguments;
                return Arg{ .str = try std.mem.join(allocator, " ", args) };
            },
            .none => return if (args.len == 0) .{ .none = {} } else error.TooManyArguments,
        }
    }
};

const ImplFn = fn (seat: *Seat, arg: Arg) void;

const Definition = struct {
    name: []const u8,
    arg_type: @TagType(Arg),
    impl: ImplFn,
};

// zig fmt: off
const str_to_read_fn = [_]Definition{
    .{ .name = "close",             .arg_type = .none,      .impl = command.close },
    .{ .name = "exit",              .arg_type = .none,      .impl = command.exit },
    .{ .name = "focus",             .arg_type = .direction, .impl = command.focus },
    .{ .name = "focus_all_tags",    .arg_type = .none,      .impl = command.focusAllTags },
    .{ .name = "focus_output",      .arg_type = .direction, .impl = command.focusOutput },
    .{ .name = "focus_tag",         .arg_type = .uint,      .impl = command.focusTag },
    .{ .name = "mod_master_count",  .arg_type = .int,       .impl = command.modMasterCount },
    .{ .name = "mod_master_factor", .arg_type = .float,     .impl = command.modMasterFactor },
    .{ .name = "mode",              .arg_type = .str,       .impl = command.mode },
    .{ .name = "send_to_output",    .arg_type = .direction, .impl = command.sendToOutput },
    .{ .name = "spawn",             .arg_type = .str,       .impl = command.spawn },
    .{ .name = "tag_view",          .arg_type = .uint,      .impl = command.tagView },
    .{ .name = "tag_view_all_tags", .arg_type = .none,      .impl = command.tagViewAllTags },
    .{ .name = "toggle_float",      .arg_type = .none,      .impl = command.toggleFloat },
    .{ .name = "toggle_tag_focus",  .arg_type = .uint,      .impl = command.toggleTagFocus },
    .{ .name = "toggle_view_tag",   .arg_type = .uint,      .impl = command.toggleViewTag },
    .{ .name = "zoom",              .arg_type = .none,      .impl = command.zoom },
};
// zig fmt: on

impl: ImplFn,
arg: Arg,

pub fn init(args: []const []const u8, allocator: *std.mem.Allocator) !Self {
    if (args.len == 0) return error.NoCommand;
    const name = args[0];

    const definition = for (str_to_read_fn) |definition| {
        if (std.mem.eql(u8, name, definition.name)) break definition;
    } else return error.UnknownCommand;

    return Self{
        .impl = definition.impl,
        .arg = try Arg.parse(definition.arg_type, args[1..], allocator),
    };
}

pub fn deinit(self: Self, allocator: *std.mem.Allocator) void {
    if (self.arg == .str) allocator.free(self.arg.str);
}

pub fn run(self: Self, seat: *Seat) void {
    self.impl(seat, self.arg);
}
