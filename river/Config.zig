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

const Self = @This();

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const globber = @import("globber");
const xkb = @import("xkbcommon");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Server = @import("Server.zig");
const Output = @import("Output.zig");
const Mode = @import("Mode.zig");
const RuleList = @import("rule_list.zig").RuleList;
const View = @import("View.zig");

pub const AttachMode = union(enum) {
    top,
    bottom,
    after: u32,
    above,
    below,
};

pub const FocusFollowsCursorMode = enum {
    disabled,
    /// Only change focus on entering a surface
    normal,
    /// Change focus on any cursor movement
    always,
};

pub const WarpCursorMode = enum {
    disabled,
    @"on-output-change",
    @"on-focus-change",
};

pub const HideCursorWhenTypingMode = enum {
    disabled,
    enabled,
};

pub const Position = struct {
    x: u31,
    y: u31,
};

pub const Dimensions = struct {
    width: u31,
    height: u31,
};

/// Color of background in RGBA with premultiplied alpha (alpha should only affect nested sessions)
background_color: [4]f32 = [_]f32{ 0.0, 0.16862745, 0.21176471, 1.0 }, // Solarized base03

/// Width of borders in pixels
border_width: u31 = 2,

/// Color of border of focused window in RGBA with premultiplied alpha
border_color_focused: [4]f32 = [_]f32{ 0.57647059, 0.63137255, 0.63137255, 1.0 }, // Solarized base1

/// Color of border of unfocused window in RGBA with premultiplied alpha
border_color_unfocused: [4]f32 = [_]f32{ 0.34509804, 0.43137255, 0.45882353, 1.0 }, // Solarized base01

/// Color of border of urgent window in RGBA with premultiplied alpha
border_color_urgent: [4]f32 = [_]f32{ 0.86274510, 0.19607843, 0.18431373, 1.0 }, // Solarized red

/// Map of keymap mode name to mode id
/// Does not own the string keys. They are owned by the corresponding Mode struct.
mode_to_id: std.StringHashMap(u32),

/// All user-defined keymap modes, indexed by mode id
modes: std.ArrayListUnmanaged(Mode),

rules: struct {
    float: RuleList(bool) = .{},
    ssd: RuleList(bool) = .{},
    tags: RuleList(u32) = .{},
    output: RuleList([]const u8) = .{},
    position: RuleList(Position) = .{},
    dimensions: RuleList(Dimensions) = .{},
    fullscreen: RuleList(bool) = .{},
} = .{},

/// The selected focus_follows_cursor mode
focus_follows_cursor: FocusFollowsCursorMode = .disabled,

/// If true, the cursor warps to the center of the focused output
warp_cursor: WarpCursorMode = .disabled,

/// The default layout namespace for outputs which have never had a per-output
/// value set. Call Output.handleLayoutNamespaceChange() on setting this if
/// Output.layout_namespace is null.
default_layout_namespace: []const u8 = &[0]u8{},

/// Bitmask restricting the tags of newly created views.
spawn_tagmask: u32 = std.math.maxInt(u32),

/// Determines where new views will be attached to the view stack.
default_attach_mode: AttachMode = .top,

/// Keyboard repeat rate in characters per second
repeat_rate: u31 = 25,

/// Keyboard repeat delay in milliseconds
repeat_delay: u31 = 600,

/// Cursor hide timeout in milliseconds
cursor_hide_timeout: u31 = 0,

/// Hide the cursor while typing
cursor_hide_when_typing: HideCursorWhenTypingMode = .disabled,

xkb_context: *xkb.Context,
/// The xkb keymap used for all keyboards
keymap: *xkb.Keymap,

pub fn init() !Self {
    const xkb_context = xkb.Context.new(.no_flags) orelse return error.XkbContextFailed;
    defer xkb_context.unref();

    // Passing null here indicates that defaults from libxkbcommon and
    // its XKB_DEFAULT_LAYOUT, XKB_DEFAULT_OPTIONS, etc. should be used.
    const keymap = xkb.Keymap.newFromNames(xkb_context, null, .no_flags) orelse return error.XkbKeymapFailed;
    defer keymap.unref();

    var self = Self{
        .mode_to_id = std.StringHashMap(u32).init(util.gpa),
        .modes = try std.ArrayListUnmanaged(Mode).initCapacity(util.gpa, 2),
        .xkb_context = xkb_context.ref(),
        .keymap = keymap.ref(),
    };
    errdefer self.deinit();

    // Start with two empty modes, "normal" and "locked"
    {
        // Normal mode, id 0
        const owned_slice = try util.gpa.dupeZ(u8, "normal");
        try self.mode_to_id.putNoClobber(owned_slice, 0);
        self.modes.appendAssumeCapacity(.{ .name = owned_slice });
    }
    {
        // Locked mode, id 1
        const owned_slice = try util.gpa.dupeZ(u8, "locked");
        try self.mode_to_id.putNoClobber(owned_slice, 1);
        self.modes.appendAssumeCapacity(.{ .name = owned_slice });
    }

    return self;
}

pub fn deinit(self: *Self) void {
    self.mode_to_id.deinit();
    for (self.modes.items) |*mode| mode.deinit();
    self.modes.deinit(util.gpa);

    self.rules.float.deinit();
    self.rules.ssd.deinit();
    self.rules.tags.deinit();
    for (self.rules.output.rules.items) |rule| {
        util.gpa.free(rule.value);
    }
    self.rules.output.deinit();
    self.rules.position.deinit();
    self.rules.dimensions.deinit();
    self.rules.fullscreen.deinit();

    util.gpa.free(self.default_layout_namespace);

    self.keymap.unref();
    self.xkb_context.unref();
}

pub fn outputRuleMatch(self: *Self, view: *View) !?*Output {
    const output_name = self.rules.output.match(view) orelse return null;
    var it = server.root.active_outputs.iterator(.forward);
    while (it.next()) |output| {
        const wlr_output = output.wlr_output;
        if (mem.eql(u8, output_name, mem.span(wlr_output.name))) return output;

        // This allows matching with "Maker Model Serial" instead of "Connector"
        const maker = wlr_output.make orelse "Unknown";
        const model = wlr_output.model orelse "Unknown";
        const serial = wlr_output.serial orelse "Unknown";
        const identifier = try fmt.allocPrint(util.gpa, "{s} {s} {s}", .{ maker, model, serial });
        defer util.gpa.free(identifier);

        if (mem.eql(u8, output_name, identifier)) return output;
    }

    return null;
}
