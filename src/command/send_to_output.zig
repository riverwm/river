const c = @import("../c.zig");
const std = @import("std");

const Arg = @import("../command.zig").Arg;
const Output = @import("../output.zig").Output;
const Seat = @import("../seat.zig").Seat;
const ViewStack = @import("../view_stack.zig").ViewStack;
const View = @import("../view.zig").View;

/// Send the focused view to the the next or the previous output, depending on
/// the bool passed. Does nothing if there is only one output.
pub fn sendToOutput(seat: *Seat, arg: Arg) void {
    @import("../log.zig").Log.Debug.log("send to output", .{});

    const direction = arg.direction;
    const root = &seat.input_manager.server.root;

    if (seat.focused_view) |view| {
        // If the noop output is focused, there is nowhere to send the view
        if (seat.focused_output == &root.noop_output) {
            std.debug.assert(root.outputs.len == 0);
            return;
        }

        // Send to the next/preg output in the list if there is one, else wrap
        const focused_node = @fieldParentPtr(std.TailQueue(Output).Node, "data", seat.focused_output);
        const target_output = switch (direction) {
            .Next => if (focused_node.next) |node| &node.data else &root.outputs.first.?.data,
            .Prev => if (focused_node.prev) |node| &node.data else &root.outputs.last.?.data,
        };

        // Move the view to the target output
        const view_node = @fieldParentPtr(ViewStack(View).Node, "view", view);
        seat.focused_output.views.remove(view_node);
        target_output.views.push(view_node);
        view.output = target_output;

        // Handle the change and focus whatever's next in the focus stack
        root.arrange();
        seat.focus(null);
    }
}
