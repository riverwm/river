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

const c = @import("../c.zig");

const Arg = @import("../command.zig").Arg;
const Seat = @import("../Seat.zig");
const View = @import("../View.zig");
const ViewStack = @import("../view_stack.zig").ViewStack;

/// Bump the focused view to the top of the stack. If the view on the top of
/// the stack is focused, bump the second view to the top.
pub fn zoom(seat: *Seat, arg: Arg) void {
    if (seat.focused_view) |current_focus| {
        const output = seat.focused_output;
        const focused_node = @fieldParentPtr(ViewStack(View).Node, "view", current_focus);

        const zoom_node = if (focused_node == output.views.first)
            if (focused_node.next) |second| second else null
        else
            focused_node;

        if (zoom_node) |to_bump| {
            output.views.remove(to_bump);
            output.views.push(to_bump);
            seat.input_manager.server.root.arrange();
            seat.focus(&to_bump.view);
        }
    }
}
