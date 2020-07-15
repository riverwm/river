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

const std = @import("std");

const Seat = @import("Seat.zig");

const impl = struct {
    const backgroundColor = @import("command/config.zig").backgroundColor;
    const borderColorFocused = @import("command/config.zig").borderColorFocused;
    const borderColorUnfocused = @import("command/config.zig").borderColorUnfocused;
    const borderWidth = @import("command/config.zig").borderWidth;
    const close = @import("command/close.zig").close;
    const declareMode = @import("command/declare_mode.zig").declareMode;
    const enterMode = @import("command/enter_mode.zig").enterMode;
    const exit = @import("command/exit.zig").exit;
    const focusOutput = @import("command/focus_output.zig").focusOutput;
    const focusView = @import("command/focus_view.zig").focusView;
    const layout = @import("command/layout.zig").layout;
    const map = @import("command/map.zig").map;
    const modMasterCount = @import("command/mod_master_count.zig").modMasterCount;
    const modMasterFactor = @import("command/mod_master_factor.zig").modMasterFactor;
    const outerPadding = @import("command/config.zig").outerPadding;
    const sendToOutput = @import("command/send_to_output.zig").sendToOutput;
    const setFocusedTags = @import("command/tags.zig").setFocusedTags;
    const setViewTags = @import("command/tags.zig").setViewTags;
    const spawn = @import("command/spawn.zig").spawn;
    const toggleFloat = @import("command/toggle_float.zig").toggleFloat;
    const toggleFocusedTags = @import("command/tags.zig").toggleFocusedTags;
    const toggleFullscreen = @import("command/toggle_fullscreen.zig").toggleFullscreen;
    const toggleViewTags = @import("command/tags.zig").toggleViewTags;
    const viewPadding = @import("command/config.zig").viewPadding;
    const xcursorTheme = @import("command/xcursor_theme.zig").xcursorTheme;
    const zoom = @import("command/zoom.zig").zoom;
};

pub const Direction = enum {
    Next,
    Prev,

    pub fn parse(str: []const u8) error{InvalidDirection}!Direction {
        return if (std.mem.eql(u8, str, "next"))
            Direction.Next
        else if (std.mem.eql(u8, str, "previous"))
            Direction.Prev
        else
            error.InvalidDirection;
    }
};

// TODO: this could be replaced with a comptime hashmap
// zig fmt: off
const str_to_impl_fn = [_]struct {
    name: []const u8,
    impl: fn (*std.mem.Allocator, *Seat, []const []const u8, *?[]const u8) Error!void,
}{
    .{ .name = "background-color",       .impl = impl.backgroundColor },
    .{ .name = "border-color-focused",   .impl = impl.borderColorFocused },
    .{ .name = "border-color-unfocused", .impl = impl.borderColorUnfocused },
    .{ .name = "border-width",           .impl = impl.borderWidth },
    .{ .name = "close",                  .impl = impl.close },
    .{ .name = "declare-mode",           .impl = impl.declareMode },
    .{ .name = "enter-mode",             .impl = impl.enterMode },
    .{ .name = "exit",                   .impl = impl.exit },
    .{ .name = "focus-output",           .impl = impl.focusOutput },
    .{ .name = "focus-view",             .impl = impl.focusView },
    .{ .name = "layout",                 .impl = impl.layout },
    .{ .name = "map",                    .impl = impl.map },
    .{ .name = "mod-master-count",       .impl = impl.modMasterCount },
    .{ .name = "mod-master-factor",      .impl = impl.modMasterFactor },
    .{ .name = "outer-padding",          .impl = impl.outerPadding },
    .{ .name = "send-to-output",         .impl = impl.sendToOutput },
    .{ .name = "set-focused-tags",       .impl = impl.setFocusedTags },
    .{ .name = "set-view-tags",          .impl = impl.setViewTags },
    .{ .name = "spawn",                  .impl = impl.spawn },
    .{ .name = "toggle-float",           .impl = impl.toggleFloat },
    .{ .name = "toggle-focused-tags",    .impl = impl.toggleFocusedTags },
    .{ .name = "toggle-fullscreen",      .impl = impl.toggleFullscreen },
    .{ .name = "toggle-view-tags",       .impl = impl.toggleViewTags },
    .{ .name = "view-padding",           .impl = impl.viewPadding },
    .{ .name = "xcursor-theme",          .impl = impl.xcursorTheme },
    .{ .name = "zoom",                   .impl = impl.zoom },
};
// zig fmt: on

pub const Error = error{
    NoCommand,
    UnknownCommand,
    NotEnoughArguments,
    TooManyArguments,
    Overflow,
    InvalidCharacter,
    InvalidDirection,
    InvalidRgba,
    UnknownOption,
    OutOfMemory,
    Other,
};

/// Run a command for the given Seat. The `args` parameter is similar to the
/// classic argv in that the command to be run is passed as the first argument.
/// The optional slice passed as the out parameter must initially be set to
/// null. If the command produces output or Error.Other is returned, the slice
/// will be set to the output of the command or a failure message, respectively.
/// The caller is then responsible for freeing that slice, which will be
/// allocated using the provided allocator.
pub fn run(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    std.debug.assert(out.* == null);
    if (args.len == 0) return Error.NoCommand;

    const impl_fn = for (str_to_impl_fn) |definition| {
        if (std.mem.eql(u8, args[0], definition.name)) break definition.impl;
    } else return Error.UnknownCommand;

    try impl_fn(allocator, seat, args, out);
}

/// Return a short error message for the given error. Passing Error.Other is UB
pub fn errToMsg(err: Error) [:0]const u8 {
    return switch (err) {
        Error.NoCommand => "no command given",
        Error.UnknownCommand => "unknown command",
        Error.UnknownOption => "unknown option",
        Error.NotEnoughArguments => "not enough arguments",
        Error.TooManyArguments => "too many arguments",
        Error.Overflow => "value out of bounds",
        Error.InvalidCharacter => "invalid character in argument",
        Error.InvalidDirection => "invalid direction. Must be 'next' or 'previous'",
        Error.InvalidRgba => "invalid color format, must be #RRGGBB or #RRGGBBAA",
        Error.OutOfMemory => "out of memory",
        Error.Other => unreachable,
    };
}
