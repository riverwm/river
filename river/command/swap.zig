// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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

const server = &@import("../main.zig").server;

const Error = @import("../command.zig").Error;
const Direction = @import("../command.zig").Direction;
const Seat = @import("../Seat.zig");
const View = @import("../View.zig");
const ViewStack = @import("../view_stack.zig").ViewStack;

/// Swap the currently focused view with either the view higher or lower in the visible stack
pub fn swap(
    _: std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
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
    var it = ViewStack(View).iter(
        focused_node,
        if (direction == .next) .forward else .reverse,
        output.pending.tags,
        filter,
    );
    var it_wrap = ViewStack(View).iter(
        if (direction == .next) output.views.first else output.views.last,
        if (direction == .next) .forward else .reverse,
        output.pending.tags,
        filter,
    );

    // skip the first node which is focused_node
    _ = it.next().?;

    const to_swap = @fieldParentPtr(
        ViewStack(View).Node,
        "view",
        // Wrap around if needed
        if (it.next()) |next| next else it_wrap.next().?,
    );

    // Dont swap when only the focused view is part of the layout
    if (focused_node == to_swap) {
        return;
    }

    output.views.swap(focused_node, to_swap);

    output.arrangeViews();
    server.root.startTransaction();
}

fn filter(view: *View, filter_tags: u32) bool {
    return view.surface != null and !view.pending.float and
        !view.pending.fullscreen and view.pending.tags & filter_tags != 0;
}
