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

const std = @import("std");
const mem = std.mem;

const globber = @import("globber");

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

pub const keyboardGroupCreate = keyboardGroupDeprecated;
pub const keyboardGroupDestroy = keyboardGroupDeprecated;
pub const keyboardGroupAdd = keyboardGroupDeprecated;
pub const keyboardGroupRemove = keyboardGroupDeprecated;

fn keyboardGroupDeprecated(_: *Seat, _: []const [:0]const u8, out: *?[]const u8) Error!void {
    out.* = try util.gpa.dupe(u8, "warning: explicit keyboard groups are deprecated, " ++
        "all keyboards are now automatically added to a single group\n");
}
