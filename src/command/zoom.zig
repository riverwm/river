const c = @import("../c.zig");

const Arg = @import("../command.zig").Arg;
const Seat = @import("../seat.zig").Seat;
const View = @import("../view.zig").View;
const ViewStack = @import("../view_stack.zig").ViewStack;

/// Bump the focused view to the top of the stack.
/// TODO: if the top of the stack is focused, bump the next visible view.
pub fn zoom(seat: *Seat, arg: Arg) void {
    if (seat.focused_view) |current_focus| {
        const output = seat.focused_output;
        const node = @fieldParentPtr(ViewStack(View).Node, "view", current_focus);
        if (node != output.views.first) {
            output.views.remove(node);
            output.views.push(node);
            seat.input_manager.server.root.arrange();
        }
    }
}
