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

const Mapping = @This();

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
) !Mapping {
    const owned_args = try util.gpa.alloc([:0]u8, command_args.len);
    errdefer util.gpa.free(owned_args);
    for (command_args, 0..) |arg, i| {
        errdefer for (owned_args[0..i]) |a| util.gpa.free(a);
        owned_args[i] = try util.gpa.dupeZ(u8, arg);
    }
    return Mapping{
        .keysym = keysym,
        .modifiers = modifiers,
        .command_args = owned_args,
        .options = options,
    };
}

pub fn deinit(mapping: Mapping) void {
    for (mapping.command_args) |arg| util.gpa.free(arg);
    util.gpa.free(mapping.command_args);
}

/// Compare mapping with given keycode, modifiers and keyboard state
pub fn match(
    mapping: Mapping,
    keycode: xkb.Keycode,
    modifiers: wlr.Keyboard.ModifierMask,
    released: bool,
    xkb_state: *xkb.State,
    method: enum { no_translate, translate },
) bool {
    if (released != mapping.options.release) return false;

    const keymap = xkb_state.getKeymap();

    // If the mapping has no pinned layout, use the active layout.
    // It doesn't matter if the index is out of range, since xkbcommon
    // will fall back to the active layout if so.
    const layout_index = mapping.options.layout_index orelse xkb_state.keyGetLayout(keycode);

    switch (method) {
        .no_translate => {
            // Get keysyms from the base layer, as if modifiers didn't change keysyms.
            // E.g. pressing `Super+Shift 1` does not translate to `Super Exclam`.
            const keysyms = keymap.keyGetSymsByLevel(
                keycode,
                layout_index,
                0,
            );

            if (@as(u32, @bitCast(modifiers)) == @as(u32, @bitCast(mapping.modifiers))) {
                for (keysyms) |sym| {
                    if (sym == mapping.keysym) {
                        return true;
                    }
                }
            }
        },
        .translate => {
            // Keysyms and modifiers as translated by xkb.
            // Modifiers used to translate the key are consumed.
            // E.g. pressing `Super+Shift 1` translates to `Super Exclam`.
            const keysyms_translated = keymap.keyGetSymsByLevel(
                keycode,
                layout_index,
                xkb_state.keyGetLevel(keycode, layout_index),
            );

            const consumed = xkb_state.keyGetConsumedMods2(keycode, .xkb);
            const modifiers_translated = @as(u32, @bitCast(modifiers)) & ~consumed;

            if (modifiers_translated == @as(u32, @bitCast(mapping.modifiers))) {
                for (keysyms_translated) |sym| {
                    if (sym == mapping.keysym) {
                        return true;
                    }
                }
            }
        },
    }

    return false;
}
