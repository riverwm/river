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

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Mode = @import("../Mode.zig");
const Error = @import("../command.zig").Error;
const Mapping = @import("../Mapping.zig");
const Seat = @import("../Seat.zig");

/// Declare a new keymap mode
pub fn declareMode(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const config = &server.config;
    const new_mode_name = args[1];

    if (config.mode_to_id.get(new_mode_name) != null) return;

    try config.mode_to_id.ensureUnusedCapacity(1);
    try config.modes.ensureUnusedCapacity(util.gpa, 1);

    const owned_name = try util.gpa.dupeZ(u8, new_mode_name);

    const id: u32 = @intCast(config.modes.items.len);
    config.mode_to_id.putAssumeCapacityNoClobber(owned_name, id);
    config.modes.appendAssumeCapacity(.{ .name = owned_name });
}
