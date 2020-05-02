const c = @import("../c.zig");
const std = @import("std");

const Arg = @import("../command.zig").Arg;
const Seat = @import("../seat.zig");

/// Modify the percent of the width of the screen that the master views occupy.
pub fn modifyMasterFactor(seat: *Seat, arg: Arg) void {
    const delta = arg.float;
    const output = seat.focused_output;
    const new_master_factor = std.math.min(
        std.math.max(output.master_factor + delta, 0.05),
        0.95,
    );
    if (new_master_factor != output.master_factor) {
        output.master_factor = new_master_factor;
        seat.input_manager.server.root.arrange();
    }
}
