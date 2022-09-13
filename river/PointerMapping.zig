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

pub const ActionType = enum {
    move,
    resize,
    command,
};

pub const Action = union(ActionType) {
    move: void,
    resize: void,
    command: []const [:0]const u8,
};

event_code: u32,
modifiers: wlr.Keyboard.ModifierMask,
action: Action,
arena: std.heap.ArenaAllocator,

pub fn init(
    event_code: u32,
    modifiers: wlr.Keyboard.ModifierMask,
    action_type: ActionType,
    command_args: []const [:0]const u8,
) !Self {
    var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(util.gpa);
    errdefer arena.deinit();

    const action: Action = switch (action_type) {
        ActionType.move => Action.move,
        ActionType.resize => Action.resize,
        ActionType.command => blk: {
            const allocator: std.mem.Allocator = arena.allocator();

            var owned_args = try std.ArrayListUnmanaged([:0]const u8).initCapacity(allocator, command_args.len);

            for (command_args) |arg| {
                const owned = try allocator.dupeZ(u8, arg);
                owned_args.appendAssumeCapacity(owned);
            }

            break :blk Action{ .command = owned_args.toOwnedSlice(allocator) };
        },
    };

    return Self{
        .event_code = event_code,
        .modifiers = modifiers,
        .action = action,
        .arena = arena,
    };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}
