const c = @import("../c.zig");
const std = @import("std");

const Arg = @import("../command.zig").Arg;
const Output = @import("../output.zig").Output;
const Seat = @import("../seat.zig").Seat;

/// Focus either the next or the previous output, depending on the bool passed.
/// Does nothing if there is only one output.
pub fn focusOutput(seat: *Seat, arg: Arg) void {
    const direction = arg.direction;
    const root = &seat.input_manager.server.root;
    // If the noop output is focused, there are no other outputs to switch to
    if (seat.focused_output == &root.noop_output) {
        std.debug.assert(root.outputs.len == 0);
        return;
    }

    // Focus the next/prev output in the list if there is one, else wrap
    const focused_node = @fieldParentPtr(std.TailQueue(Output).Node, "data", seat.focused_output);
    seat.focused_output = switch (direction) {
        .Next => if (focused_node.next) |node| &node.data else &root.outputs.first.?.data,
        .Prev => if (focused_node.prev) |node| &node.data else &root.outputs.last.?.data,
    };

    seat.focus(null);
}
