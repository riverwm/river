// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const c = @import("../c.zig");

const Error = @import("../command.zig").Error;
const Mapping = @import("../Mapping.zig");
const Seat = @import("../Seat.zig");

/// Declare a new keymap mode
pub fn declareMode(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    failure_message: *[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const config = &seat.input_manager.server.config;
    const new_mode_name = args[1];

    if (config.mode_to_id.get(new_mode_name) != null) {
        failure_message.* = try std.fmt.allocPrint(
            allocator,
            "mode '{}' already exists and cannot be re-declared",
            .{new_mode_name},
        );
        return Error.CommandFailed;
    }

    try config.mode_to_id.putNoClobber(new_mode_name, config.modes.items.len);
    errdefer _ = config.mode_to_id.remove(new_mode_name);
    try config.modes.append(std.ArrayList(Mapping).init(allocator));
}
