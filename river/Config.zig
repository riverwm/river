// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 - 2021 The River Developers
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

const wayland = @import("wayland");
const wl = wayland.server.wl;

const util = @import("util.zig");

const Server = @import("Server.zig");
const Mode = @import("Mode.zig");
const Option = @import("Option.zig");

const log = std.log.scoped(.server);

pub const FocusFollowsCursorMode = enum {
    disabled,
    /// Only change focus on entering a surface
    normal,
    /// On cursor movement the focus will be updated to the surface below the cursor
    strict,
};

/// Color of background in RGBA (alpha should only affect nested sessions)
background_color: [4]f32 = [_]f32{ 0.0, 0.16862745, 0.21176471, 1.0 }, // Solarized base03
background_color_change: wl.Listener(*Option.Value) = wl.Listener(*Option.Value).init(handleBackgroundColorChange),

/// Width of borders in pixels
border_width: u32 = 2,

/// Color of border of focused window in RGBA
border_color_focused: [4]f32 = [_]f32{ 0.57647059, 0.63137255, 0.63137255, 1.0 }, // Solarized base1
border_color_focused_change: wl.Listener(*Option.Value) = wl.Listener(*Option.Value).init(handleBorderColorFocusedChange),

/// Color of border of unfocused window in RGBA
border_color_unfocused: [4]f32 = [_]f32{ 0.34509804, 0.43137255, 0.45882353, 1.0 }, // Solarized base0
border_color_unfocused_change: wl.Listener(*Option.Value) = wl.Listener(*Option.Value).init(handleBorderColorUnfocusedChange),

/// Map of keymap mode name to mode id
mode_to_id: std.StringHashMap(usize) = std.StringHashMap(usize).init(util.gpa),

/// All user-defined keymap modes, indexed by mode id
modes: std.ArrayList(Mode) = std.ArrayList(Mode).init(util.gpa),

/// List of app_ids which will be started floating
float_filter: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(util.gpa),

/// List of app_ids which are allowed to use client side decorations
csd_filter: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(util.gpa),

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

pub fn init(self: *Self, server: *Server) !void {
    self.* = .{};

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

    // Configuration is exposed through options
    const options_manager = &server.options_manager;

    try Option.create(options_manager, "border_color_focused", .{ .string = "#586e75" }); // Solarized base1
    const border_color_focused_option = options_manager.getOption("border_color_focused").?;
    border_color_focused_option.event.update.add(&self.border_color_focused_change);

    try Option.create(options_manager, "border_color_unfocused", .{ .string = "#657b83" }); // Solarized base0
    const border_color_unfocused_option = options_manager.getOption("border_color_unfocused").?;
    border_color_unfocused_option.event.update.add(&self.border_color_unfocused_change);

    try Option.create(options_manager, "background_color", .{ .string = "#002b36" }); // Solarized base3
    const background_color_option = options_manager.getOption("background_color").?;
    background_color_option.event.update.add(&self.background_color_change);
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

fn handleBorderColorFocusedChange(listener: *wl.Listener(*Option.Value), value: *Option.Value) void {
    const self = @fieldParentPtr(Self, "border_color_focused_change", listener);
    if (value.string) |color| {
        self.border_color_focused = parseRgba(std.mem.spanZ(color)) catch return;
    }
}

fn handleBorderColorUnfocusedChange(listener: *wl.Listener(*Option.Value), value: *Option.Value) void {
    const self = @fieldParentPtr(Self, "border_color_unfocused_change", listener);
    if (value.string) |color| {
        self.border_color_unfocused = parseRgba(std.mem.spanZ(color)) catch return;
    }
}

fn handleBackgroundColorChange(listener: *wl.Listener(*Option.Value), value: *Option.Value) void {
    const self = @fieldParentPtr(Self, "background_color_change", listener);
    if (value.string) |color| {
        self.background_color = parseRgba(std.mem.spanZ(color)) catch return;
    }
}

/// Parse a color in the format #RRGGBB or #RRGGBBAA
fn parseRgba(string: []const u8) ![4]f32 {
    if (string[0] != '#' or (string.len != 7 and string.len != 9)) {
        log.err("inavlid color '{}'", .{string});
        return error.InvalidRgba;
    }

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
