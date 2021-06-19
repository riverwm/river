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

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

pub fn floatFilterAdd(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    try modifyFilter(allocator, &server.config.float_filter, args, .add);
}

pub fn floatFilterRemove(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    try modifyFilter(allocator, &server.config.float_filter, args, .remove);
}

pub fn csdFilterAdd(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    try modifyFilter(allocator, &server.config.csd_filter, args, .add);
}

pub fn csdFilterRemove(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    try modifyFilter(allocator, &server.config.csd_filter, args, .remove);
}

fn modifyFilter(
    allocator: *std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    args: []const []const u8,
    operation: enum { add, remove },
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;
    for (list.items) |*filter, i| {
        if (std.mem.eql(u8, filter.*, args[1])) {
            if (operation == .remove) {
                allocator.free(list.orderedRemove(i));
            }
            return;
        }
    }
    if (operation == .add) {
        try list.ensureUnusedCapacity(1);
        list.appendAssumeCapacity(try std.mem.dupe(allocator, u8, args[1]));
    }
}
