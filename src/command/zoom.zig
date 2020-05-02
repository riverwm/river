const c = @import("../c.zig");

const Arg = @import("../command.zig").Arg;
const Seat = @import("../seat.zig");
const View = @import("../view.zig");
const ViewStack = @import("../view_stack.zig").ViewStack;

/// Bump the focused view to the top of the stack. If the view on the top of
/// the stack is focused, bump the second view to the top.
pub fn zoom(seat: *Seat, arg: Arg) void {
    if (seat.focused_view) |current_focus| {
        const output = seat.focused_output;
        const focused_node = @fieldParentPtr(ViewStack(View).Node, "view", current_focus);

        const zoom_node = if (focused_node == output.views.first)
            if (focused_node.next) |second| second else null
        else
            focused_node;

        if (zoom_node) |to_bump| {
            output.views.remove(to_bump);
            output.views.push(to_bump);
            seat.input_manager.server.root.arrange();
            seat.focus(&to_bump.view);
        }
    }
}
