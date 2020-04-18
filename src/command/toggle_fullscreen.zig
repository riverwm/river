const c = @import("../c.zig");
const std = @import("std");

const Arg = @import("../command.zig").Arg;
const Log = @import("../log.zig").Log;
const Seat = @import("../seat.zig").Seat;
const View = @import("../view.zig").View;
const ViewStack = @import("../view_stack.zig").ViewStack;

/// Toggle fullscreen on the current focused view
pub fn fullscreen(seat: *Seat, arg: Arg) void {
    Log.Debug.log("Toggling fullscreen", .{});
    const output = seat.focused_output;
    if (seat.focused_view) |current_focus| {
        if (output.fullscreen_view != seat.focused_view) {
            output.fullscreen_view = seat.focused_view;
        } else {
            output.fullscreen_view = null;
        }
        output.root.arrange();
    }
}
