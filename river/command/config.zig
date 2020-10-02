// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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

pub fn borderWidth(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const server = seat.input_manager.server;
    server.config.border_width = try std.fmt.parseInt(u32, args[1], 10);
    server.root.arrangeAll();
    server.root.startTransaction();
}

pub fn backgroundColor(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    seat.input_manager.server.config.background_color = try parseRgba(args[1]);
}

pub fn borderColorFocused(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    seat.input_manager.server.config.border_color_focused = try parseRgba(args[1]);
}

pub fn borderColorUnfocused(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    seat.input_manager.server.config.border_color_unfocused = try parseRgba(args[1]);
}

/// Parse a color in the format #RRGGBB or #RRGGBBAA
fn parseRgba(string: []const u8) ![4]f32 {
    if (string[0] != '#' or (string.len != 7 and string.len != 9)) return error.InvalidRgba;

    const r = try std.fmt.parseInt(u8, string[1..3], 16);
    const g = try std.fmt.parseInt(u8, string[3..5], 16);
    const b = try std.fmt.parseInt(u8, string[5..7], 16);
    const a = if (string.len == 9) try std.fmt.parseInt(u8, string[7..9], 16) else 255;

    return [4]f32{
        @intToFloat(f32, r) / 255.0,
        @intToFloat(f32, g) / 255.0,
        @intToFloat(f32, b) / 255.0,
        @intToFloat(f32, a) / 255.0,
    };
}
