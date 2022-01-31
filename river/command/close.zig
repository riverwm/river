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

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

/// Close the focused view, if any.
pub fn close(
    _: std.mem.Allocator,
    seat: *Seat,
    _: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    // Note: we don't call arrange() here as it will be called
    // automatically when the view is unmapped.
    if (seat.focused == .view) seat.focused.view.close();
}
