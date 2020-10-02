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

const Self = @This();

const std = @import("std");

const util = @import("util.zig");

const Server = @import("Server.zig");
const Mode = @import("Mode.zig");

pub const FocusFollowsCursorMode = enum {
    disabled,
    /// Only change focus on entering a surface
    normal,
    /// On cursor movement the focus will be updated to the surface below the cursor
    strict,
};

/// Color of background in RGBA (alpha should only affect nested sessions)
background_color: [4]f32 = [_]f32{ 0.0, 0.16862745, 0.21176471, 1.0 }, // Solarized base03

/// Width of borders in pixels
border_width: u32 = 2,

/// Color of border of focused window in RGBA
border_color_focused: [4]f32 = [_]f32{ 0.57647059, 0.63137255, 0.63137255, 1.0 }, // Solarized base1

/// Color of border of unfocused window in RGBA
border_color_unfocused: [4]f32 = [_]f32{ 0.34509804, 0.43137255, 0.45882353, 1.0 }, // Solarized base0

/// Map of keymap mode name to mode id
mode_to_id: std.StringHashMap(usize),

/// All user-defined keymap modes, indexed by mode id
modes: std.ArrayList(Mode),

/// List of app_ids which will be started floating
float_filter: std.ArrayList([]const u8),

/// List of app_ids which are allowed to use client side decorations
csd_filter: std.ArrayList([]const u8),

/// The selected focus_follows_cursor mode
focus_follows_cursor: FocusFollowsCursorMode = .disabled,

opacity: struct {
    /// The opacity of focused views
    focused: f32 = 1.0,
    /// The opacity of unfocused views
    unfocused: f32 = 1.0,
    /// The initial opacity of new views
    initial: f32 = 1.0,
    /// View opacity transition step
    delta: f32 = 1.0,
    /// Time between view opacity transition steps in milliseconds
    delta_t: u31 = 20,
} = .{},

/// Keyboard repeat rate in characters per second
repeat_rate: u31 = 25,

/// Keyboard repeat delay in milliseconds
repeat_delay: u31 = 600,

pub fn init() !Self {
    var self = Self{
        .mode_to_id = std.StringHashMap(usize).init(util.gpa),
        .modes = std.ArrayList(Mode).init(util.gpa),
        .float_filter = std.ArrayList([]const u8).init(util.gpa),
        .csd_filter = std.ArrayList([]const u8).init(util.gpa),
    };

    errdefer self.deinit();

    // Start with two empty modes, "normal" and "locked"
    try self.modes.ensureCapacity(2);
    {
        // Normal mode, id 0
        const owned_slice = try std.mem.dupe(util.gpa, u8, "normal");
        try self.mode_to_id.putNoClobber(owned_slice, 0);
        self.modes.appendAssumeCapacity(Mode.init());
    }
    {
        // Locked mode, id 1
        const owned_slice = try std.mem.dupe(util.gpa, u8, "locked");
        try self.mode_to_id.putNoClobber(owned_slice, 1);
        self.modes.appendAssumeCapacity(Mode.init());
    }

    return self;
}

pub fn deinit(self: *Self) void {
    var it = self.mode_to_id.iterator();
    while (it.next()) |e| util.gpa.free(e.key);
    self.mode_to_id.deinit();

    for (self.modes.items) |mode| mode.deinit();
    self.modes.deinit();

    for (self.float_filter.items) |s| util.gpa.free(s);
    self.float_filter.deinit();

    for (self.csd_filter.items) |s| util.gpa.free(s);
    self.csd_filter.deinit();
}
