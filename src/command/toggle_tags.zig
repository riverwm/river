const c = @import("../c.zig");

const Arg = @import("../command.zig").Arg;
const Seat = @import("../seat.zig").Seat;

/// Toggle focus of the passsed tags.
pub fn toggleTags(seat: *Seat, arg: Arg) void {
    const tags = arg.uint;
    const output = seat.focused_output;
    const new_focused_tags = output.current_focused_tags ^ tags;
    if (new_focused_tags != 0) {
        output.pending_focused_tags = new_focused_tags;
        seat.input_manager.server.root.arrange();
    }
}
