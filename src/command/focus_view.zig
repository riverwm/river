const c = @import("../c.zig");

const Arg = @import("../command.zig").Arg;
const Seat = @import("../seat.zig").Seat;
const View = @import("../view.zig").View;
const ViewStack = @import("../view_stack.zig").ViewStack;

/// Focus either the next or the previous visible view, depending on the enum
/// passed. Does nothing if there are 1 or 0 views in the stack.
pub fn focusView(seat: *Seat, arg: Arg) void {
    const direction = arg.direction;
    const output = seat.focused_output;
    if (seat.focused_view) |current_focus| {
        // If there is a currently focused view, focus the next visible view in the stack.
        const focused_node = @fieldParentPtr(ViewStack(View).Node, "view", current_focus);
        var it = switch (direction) {
            .Next => ViewStack(View).iterator(focused_node, output.current_focused_tags),
            .Prev => ViewStack(View).reverseIterator(focused_node, output.current_focused_tags),
        };

        // Skip past the focused node
        _ = it.next();
        // Focus the next visible node if there is one
        if (it.next()) |node| {
            seat.focus(&node.view);
            return;
        }
    }

    // There is either no currently focused view or the last visible view in the
    // stack is focused and we need to wrap.
    var it = switch (direction) {
        .Next => ViewStack(View).iterator(output.views.first, output.current_focused_tags),
        .Prev => ViewStack(View).reverseIterator(output.views.last, output.current_focused_tags),
    };
    seat.focus(if (it.next()) |node| &node.view else null);
}
