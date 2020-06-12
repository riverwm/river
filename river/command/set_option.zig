// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Rishabh Das
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

const Error = @import("../command.zig").Error;
const Option = @import("../command.zig").Option;
const Seat = @import("../Seat.zig");

/// Set option to a specified value.
pub fn setOption(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    failure_message: *[]const u8,
) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 3) return Error.TooManyArguments;

    const config = &seat.focused_output.root.server.config;

    // Parse option and value.
    const option = try Option.parse(args[1]);

    // Assign value to option.
    switch (option) {
        .BorderWidth => config.border_width = try std.fmt.parseInt(u32, args[2], 10),
        .BorderFocusedColor => try config.border_focused_color.parseString(args[2]),
        .BorderUnfocusedColor => try config.border_unfocused_color.parseString(args[2]),
        .OuterPadding => config.outer_padding = try std.fmt.parseInt(u32, args[2], 10),
    }

    // 'Refresh' focused output to display the desired changes.
    seat.focused_output.root.arrange();
}
