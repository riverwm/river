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
const Output = @import("../output.zig");
const Seat = @import("../seat.zig");

/// Send the focused view to the the next or the previous output, depending on
/// the bool passed. Does nothing if there is only one output.
pub fn sendToOutput(seat: *Seat, arg: Arg) void {
    @import("../log.zig").Log.Debug.log("send to output", .{});

    const direction = arg.direction;
    const root = &seat.input_manager.server.root;

    if (seat.focused_view) |view| {
        // If the noop output is focused, there is nowhere to send the view
        if (view.output == &root.noop_output) {
            std.debug.assert(root.outputs.len == 0);
            return;
        }

        // Send to the next/preg output in the list if there is one, else wrap
        const current_node = @fieldParentPtr(std.TailQueue(Output).Node, "data", view.output);
        const destination_output = switch (direction) {
            .Next => if (current_node.next) |node| &node.data else &root.outputs.first.?.data,
            .Prev => if (current_node.prev) |node| &node.data else &root.outputs.last.?.data,
        };

        // Move the view to the target output
        view.sendToOutput(destination_output);

        // Handle the change and focus whatever's next in the focus stack
        root.arrange();
        seat.focus(null);
    }
}
