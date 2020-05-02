const c = @import("../c.zig");
const std = @import("std");

const Arg = @import("../command.zig").Arg;
const Seat = @import("../seat.zig");

/// Modify the number of master views
pub fn modifyMasterCount(seat: *Seat, arg: Arg) void {
    const delta = arg.int;
    const output = seat.focused_output;
    output.master_count = @intCast(
        u32,
        std.math.max(0, @intCast(i32, output.master_count) + delta),
    );
    seat.input_manager.server.root.arrange();
}
