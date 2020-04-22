const Seat = @import("seat.zig").Seat;

pub const Direction = enum {
    Next,
    Prev,
};

pub const Arg = union {
    int: i32,
    uint: u32,
    float: f64,
    str: []const u8,
    direction: Direction,
    none: void,
};

pub const Command = fn (seat: *Seat, arg: Arg) void;

pub usingnamespace @import("command/close_view.zig");
pub usingnamespace @import("command/exit_compositor.zig");
pub usingnamespace @import("command/focus_output.zig");
pub usingnamespace @import("command/focus_tags.zig");
pub usingnamespace @import("command/focus_view.zig");
pub usingnamespace @import("command/modify_master_count.zig");
pub usingnamespace @import("command/modify_master_factor.zig");
pub usingnamespace @import("command/send_to_output.zig");
pub usingnamespace @import("command/set_view_tags.zig");
pub usingnamespace @import("command/spawn.zig");
pub usingnamespace @import("command/toggle_tags.zig");
pub usingnamespace @import("command/toggle_view_tags.zig");
pub usingnamespace @import("command/zoom.zig");
pub usingnamespace @import("command/toggle_float.zig");
