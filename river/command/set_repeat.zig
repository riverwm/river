// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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

const server = &@import("../main.zig").server;

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

/// Set the repeat rate and delay for all keyboards.
pub fn setRepeat(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 3) return Error.TooManyArguments;

    const rate = try std.fmt.parseInt(u31, args[1], 10);
    const delay = try std.fmt.parseInt(u31, args[2], 10);

    server.config.repeat_rate = rate;
    server.config.repeat_delay = delay;

    var it = seat.keyboards.first;
    while (it) |node| : (it = node.next) {
        node.data.input_device.device.keyboard.setRepeatInfo(rate, delay);
    }
}
