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

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");
const View = @import("../View.zig");
const ViewStack = @import("../view_stack.zig").ViewStack;

/// Bump the focused view to the top of the stack. If the view on the top of
/// the stack is focused, bump the second view to the top.
pub fn zoom(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len > 1) return Error.TooManyArguments;

    if (seat.focused == .view) {
        // Only zoom views that are part of the layout
        if (seat.focused.view.pending.float or seat.focused.view.pending.fullscreen) return;

        // If the first view that is part of the layout is focused, zoom
        // the next view in the layout. Otherwise zoom the focused view.
        const output = seat.focused_output;
        var it = ViewStack(View).iterator(output.views.first, output.current.tags);
        const layout_first = while (it.next()) |node| {
            if (!node.view.pending.float and !node.view.pending.fullscreen) break node;
        } else unreachable;

        const focused_node = @fieldParentPtr(ViewStack(View).Node, "view", seat.focused.view);
        const zoom_node = if (focused_node == layout_first) blk: {
            while (it.next()) |node| {
                if (!node.view.pending.float and !node.view.pending.fullscreen) break :blk node;
            } else {
                break :blk null;
            }
        } else focused_node;

        if (zoom_node) |to_bump| {
            output.views.remove(to_bump);
            output.views.push(to_bump);
            seat.input_manager.server.root.arrange();
            seat.focus(&to_bump.view);
        }
    }
}
