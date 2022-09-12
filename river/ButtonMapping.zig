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

const util = @import("util.zig");

event_code: u32,
modifiers: wlr.Keyboard.ModifierMask,
command_args: []const [:0]const u8,

/// When set to true the mapping will be executed on button release rather than on press
release: bool,

pub fn init(
    event_code: u32,
    modifiers: wlr.Keyboard.ModifierMask,
    release: bool,
    command_args: []const []const u8,
) !Self {
    const owned_args = try util.gpa.alloc([:0]u8, command_args.len);
    errdefer util.gpa.free(owned_args);
    for (command_args) |arg, i| {
        errdefer for (owned_args[0..i]) |a| util.gpa.free(a);
        owned_args[i] = try util.gpa.dupeZ(u8, arg);
    }
    return Self{
        .event_code = event_code,
        .modifiers = modifiers,
        .release = release,
        .command_args = owned_args,
    };
}

pub fn deinit(self: Self) void {
    for (self.command_args) |arg| util.gpa.free(arg);
    util.gpa.free(self.command_args);
}

/// Compare mapping with given event code, modifiers and keyboard state
pub fn match(
    self: Self,
    event_code: u32,
    modifiers: wlr.Keyboard.ModifierMask,
    release: bool,
) bool {
    return event_code == self.event_code and std.meta.eql(modifiers, self.modifiers) and release == self.release;
}
