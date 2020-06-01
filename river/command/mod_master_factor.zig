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
const Seat = @import("../Seat.zig");

/// Modify the percent of the width of the screen that the master views occupy.
pub fn modMasterFactor(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    failure_message: *[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const delta = try std.fmt.parseFloat(f64, args[1]);
    const output = seat.focused_output;
    const new_master_factor = std.math.min(
        std.math.max(output.master_factor + delta, 0.05),
        0.95,
    );
    if (new_master_factor != output.master_factor) {
        output.master_factor = new_master_factor;
        seat.input_manager.server.root.arrange();
    }
}
