const c = @import("../c.zig");

const Arg = @import("../command.zig").Arg;
const Seat = @import("../seat.zig");

/// Make the focused view float or stop floating, depending on its current
/// state.
pub fn toggleFloat(seat: *Seat, arg: Arg) void {
    if (seat.focused_view) |view| {
        view.setFloating(!view.floating);
        view.output.root.arrange();
    }
}
