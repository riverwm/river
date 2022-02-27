// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2022 The River Developers
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

const util = @import("../util.zig");

const server = &@import("../main.zig").server;

const Config = @import("../Config.zig");
const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

pub fn cursor(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (std.mem.eql(u8, "timeout", args[1])) {
        if (args.len < 3) return Error.NotEnoughArguments;
        if (args.len > 3) return Error.TooManyArguments;
        server.config.cursor_hide_timeout = try std.fmt.parseInt(u31, args[2], 10);
        var seat_it = server.input_manager.seats.first;
        while (seat_it) |seat_node| : (seat_it = seat_node.next) {
            const seat = &seat_node.data;
            seat.cursor.unhide();
        }
    } else if (std.mem.eql(u8, "when-typing", args[1])) {
        if (args.len < 3) return Error.NotEnoughArguments;
        if (args.len > 3) return Error.TooManyArguments;
        server.config.cursor_hide_when_typing = std.meta.stringToEnum(Config.HideCursorWhenTypingMode, args[2]) orelse
            return Error.UnknownOption;
    } else {
        return Error.UnknownOption;
    }
}
