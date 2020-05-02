const c = @import("../c.zig");

const Arg = @import("../command.zig").Arg;
const Seat = @import("../seat.zig");

/// Exit the compositor, terminating the wayland session.
pub fn exitCompositor(seat: *Seat, arg: Arg) void {
    c.wl_display_terminate(seat.input_manager.server.wl_display);
}
