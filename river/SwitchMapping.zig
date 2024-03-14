// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2022 The River Developers
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

const SwitchMapping = @This();

const Switch = @import("Switch.zig");
const util = @import("util.zig");

switch_type: Switch.Type,
switch_state: Switch.State,
command_args: []const [:0]const u8,

pub fn init(
    switch_type: Switch.Type,
    switch_state: Switch.State,
    command_args: []const []const u8,
) !SwitchMapping {
    const owned_args = try util.gpa.alloc([:0]u8, command_args.len);
    errdefer util.gpa.free(owned_args);
    for (command_args, 0..) |arg, i| {
        errdefer for (owned_args[0..i]) |a| util.gpa.free(a);
        owned_args[i] = try util.gpa.dupeZ(u8, arg);
    }
    return SwitchMapping{
        .switch_type = switch_type,
        .switch_state = switch_state,
        .command_args = owned_args,
    };
}

pub fn deinit(mapping: SwitchMapping) void {
    for (mapping.command_args) |arg| util.gpa.free(arg);
    util.gpa.free(mapping.command_args);
}
