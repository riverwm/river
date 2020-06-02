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

const Log = @import("log.zig").Log;
const Server = @import("Server.zig");
const Mapping = @import("Mapping.zig");

/// Width of borders in pixels
border_width: u32,

/// Amount of view padding in pixels
view_padding: u32,

/// Amount of padding arount the outer edge of the layout in pixels
outer_padding: u32,

/// Map of keymap mode name to mode id
mode_to_id: std.StringHashMap(usize),

/// All user-defined keymap modes, indexed by mode id
modes: std.ArrayList(std.ArrayList(Mapping)),

/// List of app_ids which will be started floating
float_filter: std.ArrayList([*:0]const u8),

pub fn init(self: *Self, allocator: *std.mem.Allocator) !void {
    self.border_width = 2;
    self.view_padding = 8;
    self.outer_padding = 8;

    self.mode_to_id = std.StringHashMap(usize).init(allocator);
    try self.mode_to_id.putNoClobber("normal", 0);

    self.modes = std.ArrayList(std.ArrayList(Mapping)).init(allocator);
    try self.modes.append(std.ArrayList(Mapping).init(allocator));

    self.float_filter = std.ArrayList([*:0]const u8).init(allocator);

    // Float views with app_id "float"
    try self.float_filter.append("float");
}

pub fn deinit(self: Self, allocator: *std.mem.Allocator) void {
    self.mode_to_id.deinit();
    for (self.modes.items) |mode| {
        for (mode.items) |mapping| mapping.deinit(allocator);
        mode.deinit();
    }
    self.modes.deinit();
    self.float_filter.deinit();
}
