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

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

/// Switch focus to the passed tags.
pub fn setFocusedTags(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    const tags = try parseTags(allocator, args, out);
    if (seat.focused_output.current_focused_tags != tags) {
        seat.focused_output.pending_focused_tags = tags;
        seat.input_manager.server.root.arrange();
    }
}

/// Set the tags of the focused view.
pub fn setViewTags(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    const tags = try parseTags(allocator, args, out);
    if (seat.focused_view) |view| {
        view.pending.tags = tags;
        view.output.root.arrange();
    }
}

/// Toggle focus of the passsed tags.
pub fn toggleFocusedTags(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    const tags = try parseTags(allocator, args, out);
    const output = seat.focused_output;
    const new_focused_tags = output.current_focused_tags ^ tags;
    if (new_focused_tags != 0) {
        output.pending_focused_tags = new_focused_tags;
        seat.input_manager.server.root.arrange();
    }
}

/// Toggle the passed tags of the focused view
pub fn toggleViewTags(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    const tags = try parseTags(allocator, args, out);
    if (seat.focused_view) |view| {
        const new_tags = view.current.tags ^ tags;
        if (new_tags != 0) {
            view.pending.tags = new_tags;
            view.output.root.arrange();
        }
    }
}

fn parseTags(
    allocator: *std.mem.Allocator,
    args: []const []const u8,
    out: *?[]const u8,
) Error!u32 {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const tags = try std.fmt.parseInt(u32, args[1], 10);

    if (tags == 0) {
        out.* = try std.fmt.allocPrint(allocator, "tagmask may not be 0", .{});
        return Error.Other;
    }

    return tags;
}
