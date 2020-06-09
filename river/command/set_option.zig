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

    // Parse option and value.
    const option = try Option.parse(args[1]);
    const value = try std.fmt.parseInt(u32, args[2], 10);

    // Assign value to option.
    switch (option) {
        .BorderWidth => seat.focused_output.root.server.config.border_width = value,
        .OuterPadding => seat.focused_output.root.server.config.outer_padding = value,
    }

    // 'Refresh' focused output to display the desired changes.
    seat.focused_output.root.arrange();
}
