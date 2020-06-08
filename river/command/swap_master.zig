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

const std = @import("std");

const c = @import("../c.zig");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");
const View = @import("../View.zig");
const ViewStack = @import("../view_stack.zig").ViewStack;

/// Swap focused window with master window. If focused window is the master
/// window, swap it with either previously swapped window or second window.
pub fn swapMaster(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    failure_message: *[]const u8,
) Error!void {
    if (args.len > 1) return Error.TooManyArguments;

    if (seat.focused_view) |current_focus| {
        const output = seat.focused_output;
        const first_node: *ViewStack(View).Node = output.views.first orelse return Error.CommandFailed;
        const focused_node = @fieldParentPtr(ViewStack(View).Node, "view", current_focus);
        const state = struct{
            var last_focused_node: ?*ViewStack(View).Node = null;
        };

        var it = ViewStack(View).iterator(output.views.first, output.current_focused_tags);
        var focus_node: *ViewStack(View).Node = undefined;
        const swap_node = swap_node: {
            if (focused_node == it.next()) {
                focus_node = first_node;
                if (state.last_focused_node) |last_node| {
                    state.last_focused_node = null;
                    break :swap_node last_node;
                } else if (it.next()) |second_node| {
                    break :swap_node second_node;
                } else {
                    break :swap_node null;
                }
            } else {
                state.last_focused_node = first_node;
                focus_node = focused_node;
                break :swap_node focused_node;
            }
        };

        if (swap_node) |to_bump| {
            output.views.swap(to_bump, first_node);
            seat.input_manager.server.root.arrange();
            seat.focus(&focus_node.view);
        }
    }
}
