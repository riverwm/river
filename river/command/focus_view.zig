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

const Direction = @import("../command.zig").Direction;
const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");
const View = @import("../View.zig");
const ViewStack = @import("../view_stack.zig").ViewStack;

/// Focus either the next or the previous visible view, depending on the enum
/// passed. Does nothing if there are 1 or 0 views in the stack.
pub fn focusView(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const direction = std.meta.stringToEnum(Direction, args[1]) orelse return Error.InvalidDirection;
    const output = seat.focused_output;

    if (seat.focused == .view) {
        // If the focused view is fullscreen, do nothing
        if (seat.focused.view.current.fullscreen) return;

        // If there is a currently focused view, focus the next visible view in the stack.
        const focused_node = @fieldParentPtr(ViewStack(View).Node, "view", seat.focused.view);
        var it = switch (direction) {
            .next => ViewStack(View).iterator(focused_node, output.current.tags),
            .previous => ViewStack(View).reverseIterator(focused_node, output.current.tags),
        };

        // Skip past the focused node
        _ = it.next();
        // Focus the next visible node if there is one
        if (it.next()) |node| {
            seat.focus(&node.view);
            output.root.startTransaction();
            return;
        }
    }

    // There is either no currently focused view or the last visible view in the
    // stack is focused and we need to wrap.
    var it = switch (direction) {
        .next => ViewStack(View).iterator(output.views.first, output.current.tags),
        .previous => ViewStack(View).reverseIterator(output.views.last, output.current.tags),
    };

    seat.focus(if (it.next()) |node| &node.view else null);
    output.root.startTransaction();
}
