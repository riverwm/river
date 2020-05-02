const c = @import("../c.zig");

const Arg = @import("../command.zig").Arg;
const Seat = @import("../seat.zig");

/// Switch focus to the passed tags.
pub fn focusTags(seat: *Seat, arg: Arg) void {
    const tags = arg.uint;
    seat.focused_output.pending_focused_tags = tags;
    seat.input_manager.server.root.arrange();
}
