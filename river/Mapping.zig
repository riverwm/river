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
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const util = @import("util.zig");

keysym: xkb.Keysym,
modifiers: wlr.Keyboard.ModifierMask,
command_args: []const [:0]const u8,
options: Options,

pub const Options = struct {
    /// When set to true the mapping will be executed on key release rather than on press
    release: bool,
    /// When set to true the mapping will be executed repeatedly while key is pressed
    repeat: bool,
    // This is set for mappings with layout-pinning
    // If set, the layout with this index is always used to translate the given keycode
    layout_index: ?u32,
};

pub fn init(
    keysym: xkb.Keysym,
    modifiers: wlr.Keyboard.ModifierMask,
    command_args: []const []const u8,
    options: Options,
) !Self {
    const owned_args = try util.gpa.alloc([:0]u8, command_args.len);
    errdefer util.gpa.free(owned_args);
    for (command_args, 0..) |arg, i| {
        errdefer for (owned_args[0..i]) |a| util.gpa.free(a);
        owned_args[i] = try util.gpa.dupeZ(u8, arg);
    }
    return Self{
        .keysym = keysym,
        .modifiers = modifiers,
        .command_args = owned_args,
        .options = options,
    };
}

pub fn deinit(self: Self) void {
    for (self.command_args) |arg| util.gpa.free(arg);
    util.gpa.free(self.command_args);
}

/// Compare mapping with given keycode, modifiers and keyboard state
pub fn match(
    self: Self,
    keycode: xkb.Keycode,
    modifiers: wlr.Keyboard.ModifierMask,
    released: bool,
    xkb_state: *xkb.State,
) bool {
    if (released != self.options.release) return false;

    const keymap = xkb_state.getKeymap();

    // If the mapping has no pinned layout, use the active layout.
    // It doesn't matter if the index is out of range, since xkbcommon
    // will fall back to the active layout if so.
    const layout_index = self.options.layout_index orelse xkb_state.keyGetLayout(keycode);

    // Get keysyms from the base layer, as if modifiers didn't change keysyms.
    // E.g. pressing `Super+Shift 1` does not translate to `Super Exclam`.
    const keysyms = keymap.keyGetSymsByLevel(
        keycode,
        layout_index,
        0,
    );

    if (std.meta.eql(modifiers, self.modifiers)) {
        for (keysyms) |sym| {
            if (sym == self.keysym) {
                return true;
            }
        }
    }

    // We deliberately choose not to translate keysyms and modifiers with xkb,
    // because of strange behavior that xkb shows for some layouts and keys.
    // When pressing `Shift Space` on some layouts (Swedish among others),
    // xkb reports `Shift` as consumed. This leads to the case that we cannot
    // distinguish between `Space` and `Shift Space` presses when doing a
    // correct translation with xkb.

    return false;
}
