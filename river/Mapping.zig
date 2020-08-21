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

const c = @import("c.zig");

keysym: c.xkb_keysym_t,
modifiers: u32,
command_args: []const []const u8,

pub fn init(
    allocator: *std.mem.Allocator,
    keysym: c.xkb_keysym_t,
    modifiers: u32,
    command_args: []const []const u8,
) !Self {
    const owned_args = try allocator.alloc([]u8, command_args.len);
    errdefer allocator.free(owned_args);
    for (command_args) |arg, i| {
        errdefer for (owned_args[0..i]) |a| allocator.free(a);
        owned_args[i] = try std.mem.dupe(allocator, u8, arg);
    }
    return Self{
        .keysym = keysym,
        .modifiers = modifiers,
        .command_args = owned_args,
    };
}

pub fn deinit(self: Self, allocator: *std.mem.Allocator) void {
    for (self.command_args) |arg| allocator.free(arg);
    allocator.free(self.command_args);
}
