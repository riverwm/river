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
const util = @import("util.zig");

const Server = @import("Server.zig");
const Mapping = @import("Mapping.zig");

/// Color of background in RGBA (alpha should only affect nested sessions)
background_color: [4]f32,

/// Width of borders in pixels
border_width: u32,

/// Color of border of focused window in RGBA
border_color_focused: [4]f32,

/// Color of border of unfocused window in RGBA
border_color_unfocused: [4]f32,

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

pub fn init(self: *Self) !void {
    self.background_color = [_]f32{ 0.0, 0.16862745, 0.21176471, 1.0 }; // Solarized base03
    self.border_width = 2;
    self.border_color_focused = [_]f32{ 0.57647059, 0.63137255, 0.63137255, 1.0 }; // Solarized base1
    self.border_color_unfocused = [_]f32{ 0.34509804, 0.43137255, 0.45882353, 1.0 }; // Solarized base0
    self.view_padding = 8;
    self.outer_padding = 8;

    self.mode_to_id = std.StringHashMap(usize).init(util.gpa);
    errdefer self.mode_to_id.deinit();
    const owned_slice = try std.mem.dupe(util.gpa, u8, "normal");
    errdefer util.gpa.free(owned_slice);
    try self.mode_to_id.putNoClobber(owned_slice, 0);

    self.modes = std.ArrayList(std.ArrayList(Mapping)).init(util.gpa);
    errdefer self.modes.deinit();
    try self.modes.append(std.ArrayList(Mapping).init(util.gpa));

    self.float_filter = std.ArrayList([*:0]const u8).init(util.gpa);
    errdefer self.float_filter.deinit();

    // Float views with app_id "float"
    try self.float_filter.append("float");
}

pub fn deinit(self: Self) void {
    var it = self.mode_to_id.iterator();
    while (it.next()) |kv| util.gpa.free(kv.key);
    self.mode_to_id.deinit();

    for (self.modes.items) |mode| {
        for (mode.items) |mapping| mapping.deinit(util.gpa);
        mode.deinit();
    }
    self.modes.deinit();

    self.float_filter.deinit();
}
