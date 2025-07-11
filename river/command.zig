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

const command_impls = std.StaticStringMap(
    *const fn (*Seat, []const [:0]const u8, *?[]const u8) Error!void,
).initComptime(
    .{
        // zig fmt: off
        .{ "allow-tearing",             @import("command/config.zig").allowTearing },
        .{ "attach-mode",               @import("command/attach_mode.zig").defaultAttachMode },
        .{ "background-color",          @import("command/config.zig").backgroundColor },
        .{ "border-color-focused",      @import("command/config.zig").borderColorFocused },
        .{ "border-color-unfocused",    @import("command/config.zig").borderColorUnfocused },
        .{ "border-color-urgent",       @import("command/config.zig").borderColorUrgent },
        .{ "border-width",              @import("command/config.zig").borderWidth },
        .{ "close",                     @import("command/close.zig").close },
        .{ "declare-mode",              @import("command/declare_mode.zig").declareMode },
        .{ "default-attach-mode",       @import("command/attach_mode.zig").defaultAttachMode },
        .{ "default-layout",            @import("command/layout.zig").defaultLayout },
        .{ "enter-mode",                @import("command/enter_mode.zig").enterMode },
        .{ "exit",                      @import("command/exit.zig").exit },
        .{ "focus-follows-cursor",      @import("command/focus_follows_cursor.zig").focusFollowsCursor },
        .{ "focus-output",              @import("command/output.zig").focusOutput },
        .{ "focus-previous-tags",       @import("command/tags.zig").focusPreviousTags },
        .{ "focus-view",                @import("command/view_operations.zig").focusView },
        .{ "hide-cursor",               @import("command/cursor.zig").cursor },
        .{ "input",                     @import("command/input.zig").input },
        .{ "keyboard-group-add",        @import("command/keyboard_group.zig").keyboardGroupAdd },
        .{ "keyboard-group-create",     @import("command/keyboard_group.zig").keyboardGroupCreate },
        .{ "keyboard-group-destroy",    @import("command/keyboard_group.zig").keyboardGroupDestroy },
        .{ "keyboard-group-remove",     @import("command/keyboard_group.zig").keyboardGroupRemove },
        .{ "keyboard-layout",           @import("command/keyboard.zig").keyboardLayout },
        .{ "keyboard-layout-file",      @import("command/keyboard.zig").keyboardLayoutFile },
        .{ "list-input-configs",        @import("command/input.zig").listInputConfigs},
        .{ "list-inputs",               @import("command/input.zig").listInputs },
        .{ "list-rules",                @import("command/rule.zig").listRules},
        .{ "map",                       @import("command/map.zig").map },
        .{ "map-pointer",               @import("command/map.zig").mapPointer },
        .{ "map-switch",                @import("command/map.zig").mapSwitch },
        .{ "move",                      @import("command/move.zig").move },
        .{ "output-attach-mode",        @import("command/attach_mode.zig").outputAttachMode },
        .{ "output-layout",             @import("command/layout.zig").outputLayout },
        .{ "resize",                    @import("command/move.zig").resize },
        .{ "rule-add",                  @import("command/rule.zig").ruleAdd },
        .{ "rule-del",                  @import("command/rule.zig").ruleDel },
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
        .{ "swap",                      @import("command/view_operations.zig").swap},
        .{ "toggle-float",              @import("command/toggle_float.zig").toggleFloat },
        .{ "toggle-focused-tags",       @import("command/tags.zig").toggleFocusedTags },
        .{ "toggle-fullscreen",         @import("command/toggle_fullscreen.zig").toggleFullscreen },
        .{ "toggle-view-tags",          @import("command/tags.zig").toggleViewTags },
        .{ "unmap",                     @import("command/map.zig").unmap },
        .{ "unmap-pointer",             @import("command/map.zig").unmapPointer },
        .{ "unmap-switch",              @import("command/map.zig").unmapSwitch },
        .{ "xcursor-theme",             @import("command/xcursor_theme.zig").xcursorTheme },
        .{ "zoom",                      @import("command/zoom.zig").zoom },
        // zig fmt: on
    },
);

pub const Error = error{
    NoCommand,
    UnknownCommand,
    NotEnoughArguments,
    TooManyArguments,
    OutOfBounds,
    Overflow,
    InvalidButton,
    InvalidCharacter,
    InvalidDirection,
    InvalidGlob,
    InvalidPhysicalDirection,
    InvalidOutputIndicator,
    InvalidOrientation,
    InvalidRgba,
    InvalidValue,
    CannotReadFile,
    CannotParseFile,
    UnknownOption,
    ConflictingOptions,
    WriteFailed,
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

/// Return a short error message for the given error. Passing Error.Other is invalid.
pub fn errToMsg(err: Error) [:0]const u8 {
    return switch (err) {
        Error.NoCommand => "no command given",
        Error.UnknownCommand => "unknown command",
        Error.UnknownOption => "unknown option",
        Error.ConflictingOptions => "options conflict",
        Error.NotEnoughArguments => "not enough arguments",
        Error.TooManyArguments => "too many arguments",
        Error.OutOfBounds, Error.Overflow => "value out of bounds",
        Error.InvalidButton => "invalid button",
        Error.InvalidCharacter => "invalid character in argument",
        Error.InvalidDirection => "invalid direction. Must be 'next' or 'previous'",
        Error.InvalidGlob => "invalid glob. '*' is only allowed as the first and/or last character",
        Error.InvalidPhysicalDirection => "invalid direction. Must be 'up', 'down', 'left' or 'right'",
        Error.InvalidOutputIndicator => "invalid indicator for an output. Must be 'next', 'previous', 'up', 'down', 'left', 'right' or a valid output name",
        Error.InvalidOrientation => "invalid orientation. Must be 'horizontal', or 'vertical'",
        Error.InvalidRgba => "invalid color format, must be hexadecimal 0xRRGGBB or 0xRRGGBBAA",
        Error.InvalidValue => "invalid value",
        Error.CannotReadFile => "cannot read file",
        Error.CannotParseFile => "cannot parse file",
        Error.WriteFailed, Error.OutOfMemory => "out of memory",
        Error.Other => unreachable,
    };
}
