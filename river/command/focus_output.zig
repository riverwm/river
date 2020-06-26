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

const Direction = @import("../command.zig").Direction;
const Error = @import("../command.zig").Error;
const Output = @import("../Output.zig");
const Seat = @import("../Seat.zig");

/// Focus either the next or the previous output, depending on the bool passed.
/// Does nothing if there is only one output.
pub fn focusOutput(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const direction = try Direction.parse(args[1]);
    const root = &seat.input_manager.server.root;

    // If the noop output is focused, there are no other outputs to switch to
    if (seat.focused_output == &root.noop_output) {
        std.debug.assert(root.outputs.len == 0);
        return;
    }

    // Focus the next/prev output in the list if there is one, else wrap
    const focused_node = @fieldParentPtr(std.TailQueue(Output).Node, "data", seat.focused_output);
    seat.focusOutput(switch (direction) {
        .Next => if (focused_node.next) |node| &node.data else &root.outputs.first.?.data,
        .Prev => if (focused_node.prev) |node| &node.data else &root.outputs.last.?.data,
    });

    seat.focus(null);
}
