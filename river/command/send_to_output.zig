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

const Direction = @import("../command.zig").Direction;
const Error = @import("../command.zig").Error;
const Output = @import("../Output.zig");
const Seat = @import("../Seat.zig");

/// Send the focused view to the the next or the previous output, depending on
/// the bool passed. Does nothing if there is only one output.
pub fn sendToOutput(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const direction = std.meta.stringToEnum(Direction, args[1]) orelse return Error.InvalidDirection;

    if (seat.focused == .view) {
        // If the noop output is focused, there is nowhere to send the view
        if (seat.focused_output == &server.root.noop_output) {
            std.debug.assert(server.root.outputs.len == 0);
            return;
        }

        // Send to the next/prev output in the list if there is one, else wrap
        const current_node = @fieldParentPtr(std.TailQueue(Output).Node, "data", seat.focused_output);
        const destination_output = switch (direction) {
            .next => if (current_node.next) |node| &node.data else &server.root.outputs.first.?.data,
            .previous => if (current_node.prev) |node| &node.data else &server.root.outputs.last.?.data,
        };

        // Move the view to the target output
        seat.focused.view.sendToOutput(destination_output);

        // Handle the change and focus whatever's next in the focus stack
        seat.focus(null);
        seat.focused_output.arrangeViews();
        destination_output.arrangeViews();
        server.root.startTransaction();
    }
}
