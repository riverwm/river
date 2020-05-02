// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const Seat = @import("seat.zig");

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
