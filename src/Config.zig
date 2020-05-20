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

const Command = @import("Command.zig");
const Log = @import("log.zig").Log;
const Mode = @import("Mode.zig");
const Server = @import("Server.zig");

/// Width of borders in pixels
border_width: u32,

/// Amount of view padding in pixels
view_padding: u32,

/// Amount of padding arount the outer edge of the layout in pixels
outer_padding: u32,

/// All user-defined keybinding modes
modes: std.ArrayList(Mode),

/// List of app_ids which will be started floating
float_filter: std.ArrayList([*:0]const u8),

pub fn init(self: *Self, allocator: *std.mem.Allocator) !void {
    self.border_width = 2;
    self.view_padding = 8;
    self.outer_padding = 8;

    self.modes = std.ArrayList(Mode).init(allocator);
    try self.modes.append(try Mode.init("normal", allocator));

    self.float_filter = std.ArrayList([*:0]const u8).init(allocator);

    const normal = &self.modes.items[0];
    const mod = c.WLR_MODIFIER_LOGO;

    // Mod+Shift+Return to start an instance of alacritty
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_Return,
        .modifiers = mod | c.WLR_MODIFIER_SHIFT,
        .command = try Command.init(&[_][]const u8{ "spawn", "alacritty" }, allocator),
    });

    // Mod+Q to close the focused view
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_q,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{"close"}, allocator),
    });

    // Mod+E to exit river
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_e,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{"exit"}, allocator),
    });

    // Mod+J and Mod+K to focus the next/previous view in the layout stack
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_j,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{ "focus", "next" }, allocator),
    });
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_k,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{ "focus", "previous" }, allocator),
    });

    // Mod+Return to bump the focused view to the top of the layout stack,
    // making it the new master
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_Return,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{"zoom"}, allocator),
    });

    // Mod+H and Mod+L to increase/decrease the width of the master column
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_h,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{ "mod_master_factor", "+0.05" }, allocator),
    });
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_l,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{ "mod_master_factor", "-0.05" }, allocator),
    });

    // Mod+Shift+H and Mod+Shift+L to increment/decrement the number of
    // master views in the layout
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_h,
        .modifiers = mod | c.WLR_MODIFIER_SHIFT,
        .command = try Command.init(&[_][]const u8{ "mod_master_count", "+1" }, allocator),
    });
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_l,
        .modifiers = mod | c.WLR_MODIFIER_SHIFT,
        .command = try Command.init(&[_][]const u8{ "mod_master_count", "+1" }, allocator),
    });

    comptime var i = 0;
    inline while (i < 9) : (i += 1) {
        const str = &[_]u8{i + '0' + 1};
        // Mod+[1-9] to focus tag [1-9]
        try normal.keybinds.append(.{
            .keysym = c.XKB_KEY_1 + i,
            .modifiers = mod,
            .command = try Command.init(&[_][]const u8{ "focus_tag", str }, allocator),
        });
        // Mod+Shift+[1-9] to tag focused view with tag [1-9]
        try normal.keybinds.append(.{
            .keysym = c.XKB_KEY_1 + i,
            .modifiers = mod | c.WLR_MODIFIER_SHIFT,
            .command = try Command.init(&[_][]const u8{ "tag_view", str }, allocator),
        });
        // Mod+Ctrl+[1-9] to toggle focus of tag [1-9]
        try normal.keybinds.append(.{
            .keysym = c.XKB_KEY_1 + i,
            .modifiers = mod | c.WLR_MODIFIER_CTRL,
            .command = try Command.init(&[_][]const u8{ "toggle_tag_focus", str }, allocator),
        });
        // Mod+Shift+Ctrl+[1-9] to toggle tag [1-9] of focused view
        try normal.keybinds.append(.{
            .keysym = c.XKB_KEY_1 + i,
            .modifiers = mod | c.WLR_MODIFIER_CTRL | c.WLR_MODIFIER_SHIFT,
            .command = try Command.init(&[_][]const u8{ "toggle_view_tag", str }, allocator),
        });
    }

    // Mod+0 to focus all tags
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_0,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{"focus_all_tags"}, allocator),
    });

    // Mod+Shift+0 to tag focused view with all tags
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_0,
        .modifiers = mod | c.WLR_MODIFIER_SHIFT,
        .command = try Command.init(&[_][]const u8{"tag_view_all_tags"}, allocator),
    });

    // Mod+Period and Mod+Comma to focus the next/previous output
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_period,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{ "focus_output", "next" }, allocator),
    });
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_comma,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{ "focus_output", "previous" }, allocator),
    });

    // Mod+Shift+Period/Comma to send the focused view to the the
    // next/previous output
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_period,
        .modifiers = mod | c.WLR_MODIFIER_SHIFT,
        .command = try Command.init(&[_][]const u8{ "send_to_output", "next" }, allocator),
    });
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_comma,
        .modifiers = mod | c.WLR_MODIFIER_SHIFT,
        .command = try Command.init(&[_][]const u8{ "send_to_output", "previous" }, allocator),
    });

    // Mod+Space to toggle float
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_space,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{"toggle_float"}, allocator),
    });

    // Mod+F11 to enter passthrough mode
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_F11,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{ "mode", "passthrough" }, allocator),
    });

    try self.modes.append(try Mode.init("passthrough", allocator));

    // Mod+F11 to return to normal mode
    try self.modes.items[1].keybinds.append(.{
        .keysym = c.XKB_KEY_F11,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{ "mode", "normal" }, allocator),
    });

    // Change master orientation with Mod+{Up,Right,Down,Left}
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_Up,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{ "layout", "TopMaster" }, allocator),
    });
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_Right,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{ "layout", "RightMaster" }, allocator),
    });
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_Down,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{ "layout", "BottomMaster" }, allocator),
    });
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_Left,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{ "layout", "LeftMaster" }, allocator),
    });

    // Mod+f to change to Full layout
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_f,
        .modifiers = mod,
        .command = try Command.init(&[_][]const u8{ "layout", "Full" }, allocator),
    });

    // Float views with app_id "float"
    try self.float_filter.append("float");
}

pub fn deinit(self: Self, allocator: *std.mem.Allocator) void {
    for (self.modes.items) |*mode| mode.deinit();
    self.modes.deinit();
}

pub fn getMode(self: Self, name: []const u8) *Mode {
    for (self.modes.items) |*mode|
        if (std.mem.eql(u8, mode.name, name)) return mode;
    Log.Error.log("Mode '{}' does not exist, entering normal mode", .{name});
    for (self.modes.items) |*mode|
        if (std.mem.eql(u8, mode.name, "normal")) return mode;
    unreachable;
}
