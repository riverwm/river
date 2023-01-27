// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
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
const Seat = @import("../Seat.zig");
const View = @import("../View.zig");
const ViewStack = @import("../view_stack.zig").ViewStack;

/// Bump the focused view to the top of the stack. If the view on the top of
/// the stack is focused, bump the second view to the top.
pub fn zoom(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len > 1) return Error.TooManyArguments;

    if (seat.focused == .view) {
        // Only zoom views that are part of the layout
        if (seat.focused.view.pending.float or seat.focused.view.pending.fullscreen) return;

        // If the first view that is part of the layout is focused, zoom
        // the next view in the layout. Otherwise zoom the focused view.
        const output = seat.focused_output;
        var it = ViewStack(View).iter(output.views.first, .forward, output.pending.tags, filter);
        const layout_first = @fieldParentPtr(ViewStack(View).Node, "view", it.next().?);

        const focused_node = @fieldParentPtr(ViewStack(View).Node, "view", seat.focused.view);
        const zoom_node = if (focused_node == layout_first)
            if (it.next()) |view| @fieldParentPtr(ViewStack(View).Node, "view", view) else null
        else
            focused_node;

        if (zoom_node) |to_bump| {
            output.views.remove(to_bump);
            output.views.push(to_bump);
            seat.focus(&to_bump.view);
            output.arrangeViews();
            server.root.startTransaction();
        }
    }
}

fn filter(view: *View, filter_tags: u32) bool {
    return view.tree.node.enabled and !view.pending.float and
        !view.pending.fullscreen and view.pending.tags & filter_tags != 0;
}
