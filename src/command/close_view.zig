const c = @import("../c.zig");

const Arg = @import("../command.zig").Arg;
const Seat = @import("../seat.zig").Seat;

/// Close the focused view, if any.
pub fn close_view(seat: *Seat, arg: Arg) void {
    if (seat.focused_view) |view| {
        // Note: we don't call arrange() here as it will be called
        // automatically when the view is unmapped.
        c.wlr_xdg_toplevel_send_close(view.wlr_xdg_surface);
    }
}
