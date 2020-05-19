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

const Arg = @import("../Command.zig").Arg;
const Seat = @import("../Seat.zig");

/// Toggle focus of the passsed tags.
pub fn toggleTagFocus(seat: *Seat, arg: Arg) void {
    const tags = @as(u32, 1) << @intCast(u5, arg.uint - 1);
    const output = seat.focused_output;
    const new_focused_tags = output.current_focused_tags ^ tags;
    if (new_focused_tags != 0) {
        output.pending_focused_tags = new_focused_tags;
        seat.input_manager.server.root.arrange();
    }
}
