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

const c = @import("../c.zig");

const Arg = @import("../command.zig").Arg;
const Seat = @import("../seat.zig");

/// Exit the compositor, terminating the wayland session.
pub fn exitCompositor(seat: *Seat, arg: Arg) void {
    c.wl_display_terminate(seat.input_manager.server.wl_display);
}
