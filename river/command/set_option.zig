// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Rishabh Das
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

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

pub const Option = enum {
    border_width,
    border_color_focused,
    border_color_unfocused,
    outer_padding,
};

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
    const option = std.meta.stringToEnum(Option, args[1]) orelse return Error.UnknownOption;

    // Assign value to option.
    switch (option) {
        .border_width => config.border_width = try std.fmt.parseInt(u32, args[2], 10),
        .border_color_focused => try config.border_color_focused.parseString(args[2]),
        .border_color_unfocused => try config.border_color_unfocused.parseString(args[2]),
        .outer_padding => config.outer_padding = try std.fmt.parseInt(u32, args[2], 10),
    }

    // 'Refresh' focused output to display the desired changes.
    seat.focused_output.root.arrange();
}
