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

const Keybind = @import("Keybind.zig");

/// The name of the mode
name: []const u8,

/// The list of active keybindings for this mode
keybinds: std.ArrayList(Keybind),

pub fn init(name: []const u8, allocator: *std.mem.Allocator) !Self {
    const owned_name = try std.mem.dupe(allocator, u8, name);
    return Self{
        .name = owned_name,
        .keybinds = std.ArrayList(Keybind).init(allocator),
    };
}

pub fn deinit(self: Self) void {
    const allocator = self.keybinds.allocator;
    allocator.free(self.name);
    for (self.keybinds.items) |keybind| keybind.deinit(allocator);
    self.keybinds.deinit();
}
