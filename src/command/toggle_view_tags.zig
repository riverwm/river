const c = @import("../c.zig");

const Arg = @import("../command.zig").Arg;
const Seat = @import("../seat.zig").Seat;

/// Toggle the passed tags of the focused view
pub fn toggleViewTags(seat: *Seat, arg: Arg) void {
    const tags = arg.uint;
    if (seat.focused_view) |view| {
        const new_tags = view.current_tags ^ tags;
        if (new_tags != 0) {
            view.pending_tags = new_tags;
            seat.input_manager.server.root.arrange();
        }
    }
}
