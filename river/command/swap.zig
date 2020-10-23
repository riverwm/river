// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Marten Ringwelski
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
const Direction = @import("../command.zig").Direction;
const Seat = @import("../Seat.zig");
const View = @import("../View.zig");
const ViewStack = @import("../view_stack.zig").ViewStack;

/// Swap the currently focused view with either the view higher or lower in the visible stack
pub fn swap(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    if (seat.focused != .view)
        return;

    // Filter out everything that is not part of the current layout
    if (seat.focused.view.pending.float or seat.focused.view.pending.fullscreen) return;

    const direction = std.meta.stringToEnum(Direction, args[1]) orelse return Error.InvalidDirection;

    const focused_node = @fieldParentPtr(ViewStack(View).Node, "view", seat.focused.view);
    const output = seat.focused_output;
    var it = if (direction == .next) ViewStack(View).iter(focused_node, .forward, output.pending.tags, filter)
        else ViewStack(View).iter(focused_node, .reverse, output.pending.tags, filter);
    var it_wrap = if (direction == .next) ViewStack(View).iter(output.views.first, .forward, output.pending.tags, filter)
        else ViewStack(View).iter(output.views.last, .forward, output.pending.tags, filter);

    // skip the first node which is focused_node
    _ = it.next().?;

    // Wrap around if needed
    const to_swap = if (it.next()) |next| @fieldParentPtr(ViewStack(View).Node, "view", next)
        else @fieldParentPtr(ViewStack(View).Node, "view", it_wrap.next().?);

    // Dont swap when only the focused view is part of the layout
    if (focused_node == to_swap) {
        return;
    }

    output.views.swap(focused_node, to_swap);

    output.arrangeViews();
    output.root.startTransaction();
}

fn filter(view: *View, filter_tags: u32) bool {
    return !view.destroying and !view.pending.float and
        !view.pending.fullscreen and view.pending.tags & filter_tags != 0;
}
