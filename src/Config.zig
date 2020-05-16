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
const command = @import("command.zig");

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
        .command = command.spawn,
        .arg = .{ .str = "alacritty" },
    });

    // Mod+Q to close the focused view
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_q,
        .modifiers = mod,
        .command = command.close_view,
        .arg = .{ .none = {} },
    });

    // Mod+E to exit river
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_e,
        .modifiers = mod,
        .command = command.exitCompositor,
        .arg = .{ .none = {} },
    });

    // Mod+J and Mod+K to focus the next/previous view in the layout stack
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_j,
        .modifiers = mod,
        .command = command.focusView,
        .arg = .{ .direction = .Next },
    });
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_k,
        .modifiers = mod,
        .command = command.focusView,
        .arg = .{ .direction = .Prev },
    });

    // Mod+Return to bump the focused view to the top of the layout stack,
    // making it the new master
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_Return,
        .modifiers = mod,
        .command = command.zoom,
        .arg = .{ .none = {} },
    });

    // Mod+H and Mod+L to increase/decrease the width of the master column
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_h,
        .modifiers = mod,
        .command = command.modifyMasterFactor,
        .arg = .{ .float = 0.05 },
    });
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_l,
        .modifiers = mod,
        .command = command.modifyMasterFactor,
        .arg = .{ .float = -0.05 },
    });

    // Mod+Shift+H and Mod+Shift+L to increment/decrement the number of
    // master views in the layout
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_h,
        .modifiers = mod | c.WLR_MODIFIER_SHIFT,
        .command = command.modifyMasterCount,
        .arg = .{ .int = 1 },
    });
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_l,
        .modifiers = mod | c.WLR_MODIFIER_SHIFT,
        .command = command.modifyMasterCount,
        .arg = .{ .int = -1 },
    });

    comptime var i = 0;
    inline while (i < 9) : (i += 1) {
        // Mod+[1-9] to focus tag [1-9]
        try normal.keybinds.append(.{
            .keysym = c.XKB_KEY_1 + i,
            .modifiers = mod,
            .command = command.focusTags,
            .arg = .{ .uint = 1 << i },
        });
        // Mod+Shift+[1-9] to tag focused view with tag [1-9]
        try normal.keybinds.append(.{
            .keysym = c.XKB_KEY_1 + i,
            .modifiers = mod | c.WLR_MODIFIER_SHIFT,
            .command = command.setViewTags,
            .arg = .{ .uint = 1 << i },
        });
        // Mod+Ctrl+[1-9] to toggle focus of tag [1-9]
        try normal.keybinds.append(.{
            .keysym = c.XKB_KEY_1 + i,
            .modifiers = mod | c.WLR_MODIFIER_CTRL,
            .command = command.toggleTags,
            .arg = .{ .uint = 1 << i },
        });
        // Mod+Shift+Ctrl+[1-9] to toggle tag [1-9] of focused view
        try normal.keybinds.append(.{
            .keysym = c.XKB_KEY_1 + i,
            .modifiers = mod | c.WLR_MODIFIER_CTRL | c.WLR_MODIFIER_SHIFT,
            .command = command.toggleViewTags,
            .arg = .{ .uint = 1 << i },
        });
    }

    // Mod+0 to focus all tags
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_0,
        .modifiers = mod,
        .command = command.focusTags,
        .arg = .{ .uint = 0xFFFFFFFF },
    });

    // Mod+Shift+0 to tag focused view with all tags
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_0,
        .modifiers = mod | c.WLR_MODIFIER_SHIFT,
        .command = command.setViewTags,
        .arg = .{ .uint = 0xFFFFFFFF },
    });

    // Mod+Period and Mod+Comma to focus the next/previous output
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_period,
        .modifiers = mod,
        .command = command.focusOutput,
        .arg = .{ .direction = .Next },
    });
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_comma,
        .modifiers = mod,
        .command = command.focusOutput,
        .arg = .{ .direction = .Prev },
    });

    // Mod+Shift+Period/Comma to send the focused view to the the
    // next/previous output
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_period,
        .modifiers = mod | c.WLR_MODIFIER_SHIFT,
        .command = command.sendToOutput,
        .arg = .{ .direction = .Next },
    });
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_comma,
        .modifiers = mod | c.WLR_MODIFIER_SHIFT,
        .command = command.sendToOutput,
        .arg = .{ .direction = .Prev },
    });

    // Mod+Space to toggle float
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_space,
        .modifiers = mod,
        .command = command.toggleFloat,
        .arg = .{ .none = {} },
    });

    // Mod+F11 to enter passthrough mode
    try normal.keybinds.append(.{
        .keysym = c.XKB_KEY_F11,
        .modifiers = mod,
        .command = command.mode,
        .arg = .{ .str = "passthrough" },
    });

    try self.modes.append(try Mode.init("passthrough", allocator));

    // Mod+F11 to return to normal mode
    try self.modes.items[1].keybinds.append(.{
        .keysym = c.XKB_KEY_F11,
        .modifiers = mod,
        .command = command.mode,
        .arg = .{ .str = "normal" },
    });

    // Float views with app_id "float"
    try self.float_filter.append("float");
}

pub fn getMode(self: Self, name: []const u8) *Mode {
    for (self.modes.items) |*mode|
        if (std.mem.eql(u8, mode.name, name)) return mode;
    Log.Error.log("Mode '{}' does not exist, entering normal mode", .{name});
    for (self.modes.items) |*mode|
        if (std.mem.eql(u8, mode.name, "normal")) return mode;
    unreachable;
}
