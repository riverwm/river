const c = @import("../c.zig");

const Arg = @import("../command.zig").Arg;
const Seat = @import("../seat.zig");

/// Set the tags of the focused view.
pub fn setViewTags(seat: *Seat, arg: Arg) void {
    const tags = arg.uint;
    if (seat.focused_view) |view| {
        if (view.current_tags != tags) {
            view.pending_tags = tags;
            seat.input_manager.server.root.arrange();
        }
    }
}
