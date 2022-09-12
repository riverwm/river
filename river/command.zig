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

const std = @import("std");
const assert = std.debug.assert;

const Seat = @import("Seat.zig");

pub const Direction = enum {
    next,
    previous,
};

pub const PhysicalDirection = enum {
    up,
    down,
    left,
    right,
};

pub const Orientation = enum {
    horizontal,
    vertical,
};

// zig fmt: off
const command_impls = std.ComptimeStringMap(
    fn (*Seat, []const [:0]const u8, *?[]const u8) Error!void,
    .{
        .{ "attach-mode",               @import("command/attach_mode.zig").attachMode },
        .{ "background-color",          @import("command/config.zig").backgroundColor },
        .{ "border-color-focused",      @import("command/config.zig").borderColorFocused },
        .{ "border-color-unfocused",    @import("command/config.zig").borderColorUnfocused },
        .{ "border-color-urgent",       @import("command/config.zig").borderColorUrgent },
        .{ "border-width",              @import("command/config.zig").borderWidth },
        .{ "close",                     @import("command/close.zig").close },
        .{ "csd-filter-add",            @import("command/filter.zig").csdFilterAdd },
        .{ "csd-filter-remove",         @import("command/filter.zig").csdFilterRemove },
        .{ "declare-mode",              @import("command/declare_mode.zig").declareMode },
        .{ "default-layout",            @import("command/layout.zig").defaultLayout },
        .{ "enter-mode",                @import("command/enter_mode.zig").enterMode },
        .{ "exit",                      @import("command/exit.zig").exit },
        .{ "float-filter-add",          @import("command/filter.zig").floatFilterAdd },
        .{ "float-filter-remove",       @import("command/filter.zig").floatFilterRemove },
        .{ "focus-follows-cursor",      @import("command/focus_follows_cursor.zig").focusFollowsCursor },
        .{ "focus-output",              @import("command/output.zig").focusOutput },
        .{ "focus-previous-tags",       @import("command/tags.zig").focusPreviousTags },
        .{ "focus-view",                @import("command/focus_view.zig").focusView },
        .{ "hide-cursor",               @import("command/cursor.zig").cursor },
        .{ "input",                     @import("command/input.zig").input },
        .{ "list-input-configs",        @import("command/input.zig").listInputConfigs},
        .{ "list-inputs",               @import("command/input.zig").listInputs },
        .{ "map",                       @import("command/map.zig").map },
        .{ "map-button",                @import("command/map.zig").mapButton },
        .{ "map-pointer",               @import("command/map.zig").mapPointer },
        .{ "map-switch",                @import("command/map.zig").mapSwitch },
        .{ "move",                      @import("command/move.zig").move },
        .{ "output-layout",             @import("command/layout.zig").outputLayout },
        .{ "resize",                    @import("command/move.zig").resize },
        .{ "send-layout-cmd",           @import("command/layout.zig").sendLayoutCmd },
        .{ "send-to-output",            @import("command/output.zig").sendToOutput },
        .{ "send-to-previous-tags",     @import("command/tags.zig").sendToPreviousTags },
        .{ "set-cursor-warp",           @import("command/config.zig").setCursorWarp },
        .{ "set-focused-tags",          @import("command/tags.zig").setFocusedTags },
        .{ "set-repeat",                @import("command/set_repeat.zig").setRepeat },
        .{ "set-view-tags",             @import("command/tags.zig").setViewTags },
        .{ "snap",                      @import("command/move.zig").snap },
        .{ "spawn",                     @import("command/spawn.zig").spawn },
        .{ "spawn-tagmask",             @import("command/tags.zig").spawnTagmask },
        .{ "swap",                      @import("command/swap.zig").swap},
        .{ "toggle-float",              @import("command/toggle_float.zig").toggleFloat },
        .{ "toggle-focused-tags",       @import("command/tags.zig").toggleFocusedTags },
        .{ "toggle-fullscreen",         @import("command/toggle_fullscreen.zig").toggleFullscreen },
        .{ "toggle-view-tags",          @import("command/tags.zig").toggleViewTags },
        .{ "unmap",                     @import("command/map.zig").unmap },
        .{ "unmap-button",              @import("command/map.zig").unmapButton },
        .{ "unmap-pointer",             @import("command/map.zig").unmapPointer },
        .{ "unmap-switch",              @import("command/map.zig").unmapSwitch },
        .{ "xcursor-theme",             @import("command/xcursor_theme.zig").xcursorTheme },
        .{ "zoom",                      @import("command/zoom.zig").zoom },
    },
);
// zig fmt: on

pub const Error = error{
    NoCommand,
    UnknownCommand,
    NotEnoughArguments,
    TooManyArguments,
    Overflow,
    InvalidButton,
    InvalidCharacter,
    InvalidDirection,
    InvalidPhysicalDirection,
    InvalidOutputIndicator,
    InvalidOrientation,
    InvalidRgba,
    InvalidValue,
    UnknownOption,
    ConflictingOptions,
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
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    assert(out.* == null);
    if (args.len == 0) return Error.NoCommand;
    const impl_fn = command_impls.get(args[0]) orelse return Error.UnknownCommand;
    try impl_fn(seat, args, out);
}

/// Return a short error message for the given error. Passing Error.Other is UB
pub fn errToMsg(err: Error) [:0]const u8 {
    return switch (err) {
        Error.NoCommand => "no command given",
        Error.UnknownCommand => "unknown command",
        Error.UnknownOption => "unknown option",
        Error.ConflictingOptions => "options conflict",
        Error.NotEnoughArguments => "not enough arguments",
        Error.TooManyArguments => "too many arguments",
        Error.Overflow => "value out of bounds",
        Error.InvalidButton => "invalid button",
        Error.InvalidCharacter => "invalid character in argument",
        Error.InvalidDirection => "invalid direction. Must be 'next' or 'previous'",
        Error.InvalidPhysicalDirection => "invalid direction. Must be 'up', 'down', 'left' or 'right'",
        Error.InvalidOutputIndicator => "invalid indicator for an output. Must be 'next', 'previous', 'up', 'down', 'left', 'right' or a valid output name",
        Error.InvalidOrientation => "invalid orientation. Must be 'horizontal', or 'vertical'",
        Error.InvalidRgba => "invalid color format, must be hexadecimal 0xRRGGBB or 0xRRGGBBAA",
        Error.InvalidValue => "invalid value",
        Error.OutOfMemory => "out of memory",
        Error.Other => unreachable,
    };
}
