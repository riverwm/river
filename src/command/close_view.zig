const c = @import("../c.zig");

const Arg = @import("../command.zig").Arg;
const Seat = @import("../seat.zig").Seat;

/// Close the focused view, if any.
pub fn close_view(seat: *Seat, arg: Arg) void {
    if (seat.focused_view) |view| {
        view.close();
    }
}
