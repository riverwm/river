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

const Arg = @import("../command.zig").Arg;
const Seat = @import("../Seat.zig");

/// Modify the number of master views
pub fn modifyMasterCount(seat: *Seat, arg: Arg) void {
    const delta = arg.int;
    const output = seat.focused_output;
    output.master_count = @intCast(
        u32,
        std.math.max(0, @intCast(i32, output.master_count) + delta),
    );
    seat.input_manager.server.root.arrange();
}
