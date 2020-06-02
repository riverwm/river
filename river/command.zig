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

const Seat = @import("Seat.zig");

const impl = struct {
    const close = @import("command/close.zig").close;
    const declareMode = @import("command/declare_mode.zig").declareMode;
    const enterMode = @import("command/enter_mode.zig").enterMode;
    const exit = @import("command/exit.zig").exit;
    const focusView = @import("command/focus_view.zig").focusView;
    const focusAllTags = @import("command/focus_all_tags.zig").focusAllTags;
    const focusOutput = @import("command/focus_output.zig").focusOutput;
    const map = @import("command/map.zig").map;
    const focusTag = @import("command/focus_tag.zig").focusTag;
    const layout = @import("command/layout.zig").layout;
    const modMasterCount = @import("command/mod_master_count.zig").modMasterCount;
    const modMasterFactor = @import("command/mod_master_factor.zig").modMasterFactor;
    const sendToOutput = @import("command/send_to_output.zig").sendToOutput;
    const spawn = @import("command/spawn.zig").spawn;
    const tagView = @import("command/tag_view.zig").tagView;
    const tagViewAllTags = @import("command/tag_view_all_tags.zig").tagViewAllTags;
    const toggleFloat = @import("command/toggle_float.zig").toggleFloat;
    const toggleTagFocus = @import("command/toggle_tag_focus.zig").toggleTagFocus;
    const toggleViewTag = @import("command/toggle_view_tag.zig").toggleViewTag;
    const zoom = @import("command/zoom.zig").zoom;
};

pub const Direction = enum {
    Next,
    Prev,

    pub fn parse(str: []const u8) error{InvalidDirection}!Direction {
        return if (std.mem.eql(u8, str, "next"))
            Direction.Next
        else if (std.mem.eql(u8, str, "previous"))
            Direction.Prev
        else
            error.InvalidDirection;
    }
};

const Definition = struct {
    name: []const u8,
    impl: fn (*std.mem.Allocator, *Seat, []const []const u8, *[]const u8) Error!void,
};

// TODO: this could be replaced with a comptime hashmap
// zig fmt: off
const str_to_impl_fn = [_]Definition{
    .{ .name = "close",             .impl = impl.close },
    .{ .name = "declare-mode",      .impl = impl.declareMode},
    .{ .name = "enter-mode",        .impl = impl.enterMode },
    .{ .name = "exit",              .impl = impl.exit },
    .{ .name = "focus-view",        .impl = impl.focusView },
    .{ .name = "focus-all-tags",    .impl = impl.focusAllTags },
    .{ .name = "focus-output",      .impl = impl.focusOutput },
    .{ .name = "focus-tag",         .impl = impl.focusTag },
    .{ .name = "layout",            .impl = impl.layout },
    .{ .name = "mod-master-count",  .impl = impl.modMasterCount },
    .{ .name = "mod-master-factor", .impl = impl.modMasterFactor },
    .{ .name = "send-to-output",    .impl = impl.sendToOutput },
    .{ .name = "spawn",             .impl = impl.spawn },
    .{ .name = "map",               .impl = impl.map },
    .{ .name = "tag-view",          .impl = impl.tagView },
    .{ .name = "tag-view-all-tags", .impl = impl.tagViewAllTags },
    .{ .name = "toggle-float",      .impl = impl.toggleFloat },
    .{ .name = "toggle-tag-focus",  .impl = impl.toggleTagFocus },
    .{ .name = "toggle-view-tag",   .impl = impl.toggleViewTag },
    .{ .name = "zoom",              .impl = impl.zoom },
};
// zig fmt: on

pub const Error = error{
    NoCommand,
    UnknownCommand,
    NotEnoughArguments,
    TooManyArguments,
    Overflow,
    InvalidCharacter,
    InvalidDirection,
    OutOfMemory,
    CommandFailed,
};

/// Run a command for the given Seat. The `args` parameter is similar to the
/// classic argv in that the command to be run is passed as the first argument.
/// If the command fails with Error.CommandFailed, a failure message will be
/// allocated and the slice pointed to by the `failure_message` parameter will
/// be set to point to it. The caller is responsible for freeing this message
/// in the case of failure.
pub fn run(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    failure_message: *[]const u8,
) Error!void {
    if (args.len == 0) return Error.NoCommand;

    const name = args[0];
    const impl_fn = for (str_to_impl_fn) |definition| {
        if (std.mem.eql(u8, name, definition.name)) break definition.impl;
    } else return Error.UnknownCommand;

    try impl_fn(allocator, seat, args, failure_message);
}
