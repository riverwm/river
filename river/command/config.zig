// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;

const server = &@import("../main.zig").server;

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");
const Config = @import("../Config.zig");

pub fn allowTearing(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const arg = std.meta.stringToEnum(enum { enabled, disabled }, args[1]) orelse
        return Error.UnknownOption;

    server.config.allow_tearing = arg == .enabled;
}

pub fn borderWidth(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    server.config.border_width = try fmt.parseInt(u31, args[1], 10);
    server.root.applyPending();
}

pub fn backgroundColor(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    server.config.background_color = try parseRgba(args[1]);
    var it = server.root.all_outputs.iterator(.forward);
    while (it.next()) |output| {
        output.layers.background_color_rect.setColor(&server.config.background_color);
    }
}

pub fn borderColorFocused(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    server.config.border_color_focused = try parseRgba(args[1]);
    server.root.applyPending();
}

pub fn borderColorUnfocused(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    server.config.border_color_unfocused = try parseRgba(args[1]);
    server.root.applyPending();
}

pub fn borderColorUrgent(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    server.config.border_color_urgent = try parseRgba(args[1]);
    server.root.applyPending();
}

pub fn setCursorWarp(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;
    server.config.warp_cursor = std.meta.stringToEnum(Config.WarpCursorMode, args[1]) orelse
        return Error.UnknownOption;
}

/// Parse a color in the format 0xRRGGBB or 0xRRGGBBAA. Returned color has premultiplied alpha.
fn parseRgba(string: []const u8) ![4]f32 {
    if (string.len != 8 and string.len != 10) return error.InvalidRgba;
    if (string[0] != '0' or string[1] != 'x') return error.InvalidRgba;

    const r = try fmt.parseInt(u8, string[2..4], 16);
    const g = try fmt.parseInt(u8, string[4..6], 16);
    const b = try fmt.parseInt(u8, string[6..8], 16);
    const a = if (string.len == 10) try fmt.parseInt(u8, string[8..10], 16) else 255;

    const alpha = @as(f32, @floatFromInt(a)) / 255.0;

    return [4]f32{
        @as(f32, @floatFromInt(r)) / 255.0 * alpha,
        @as(f32, @floatFromInt(g)) / 255.0 * alpha,
        @as(f32, @floatFromInt(b)) / 255.0 * alpha,
        alpha,
    };
}
