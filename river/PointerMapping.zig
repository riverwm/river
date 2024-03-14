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

const PointerMapping = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");

const util = @import("util.zig");

pub const Action = union(enum) {
    move: void,
    resize: void,
    command: []const [:0]const u8,
};

event_code: u32,
modifiers: wlr.Keyboard.ModifierMask,
action: Action,
/// Owns the memory backing the arguments if action is a command.
arena_state: std.heap.ArenaAllocator.State,

pub fn init(
    event_code: u32,
    modifiers: wlr.Keyboard.ModifierMask,
    action_type: std.meta.Tag(Action),
    command_args: []const [:0]const u8,
) !PointerMapping {
    assert(action_type == .command or command_args.len == 1);

    var arena = std.heap.ArenaAllocator.init(util.gpa);
    errdefer arena.deinit();

    const action: Action = switch (action_type) {
        .move => .move,
        .resize => .resize,
        .command => blk: {
            const arena_allocator = arena.allocator();

            const owned_args = try arena_allocator.alloc([:0]const u8, command_args.len);
            for (command_args, 0..) |arg, i| {
                owned_args[i] = try arena_allocator.dupeZ(u8, arg);
            }

            break :blk .{ .command = owned_args };
        },
    };

    return PointerMapping{
        .event_code = event_code,
        .modifiers = modifiers,
        .action = action,
        .arena_state = arena.state,
    };
}

pub fn deinit(pointer_mapping: *PointerMapping) void {
    pointer_mapping.arena_state.promote(util.gpa).deinit();
    pointer_mapping.* = undefined;
}
