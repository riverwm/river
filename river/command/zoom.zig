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
const assert = std.debug.assert;

const server = &@import("../main.zig").server;

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");
const View = @import("../View.zig");

/// Bump the focused view to the top of the stack. If the view on the top of
/// the stack is focused, bump the second view to the top.
pub fn zoom(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len > 1) return Error.TooManyArguments;

    if (seat.focused != .view) return;
    if (seat.focused.view.pending.float or seat.focused.view.pending.fullscreen) return;

    const output = seat.focused_output orelse return;

    const layout_first = blk: {
        var it = output.pending.wm_stack.iterator(.forward);
        while (it.next()) |view| {
            if (view.pending.tags & output.pending.tags != 0 and !view.pending.float) break :blk view;
        } else {
            // If we are focusing a view that is not fullscreen or floating
            // it must be visible and in the layout.
            unreachable;
        }
    };

    // If the first view that is part of the layout is focused, zoom
    // the next view in the layout if any. Otherwise zoom the focused view.
    const zoom_target = blk: {
        if (seat.focused.view == layout_first) {
            var it = output.pending.wm_stack.iterator(.forward);
            while (it.next()) |view| {
                if (view == seat.focused.view) break;
            } else {
                unreachable;
            }

            while (it.next()) |view| {
                if (view.pending.tags & output.pending.tags != 0 and !view.pending.float) break :blk view;
            } else {
                break :blk null;
            }
        } else {
            break :blk seat.focused.view;
        }
    };

    if (zoom_target) |target| {
        assert(!target.pending.float);
        assert(!target.pending.fullscreen);

        target.pending_wm_stack_link.remove();
        output.pending.wm_stack.prepend(target);
        seat.focus(target);
        // Focus may not actually change here so seat.focus() may not automatically warp the cursor.
        // Nevertheless, a cursor warp seems to be what users expect with `set-cursor-warp on-focus`
        // configured, especially in combination with focus-follows-cursor.
        seat.cursor.may_need_warp = true;
        server.root.applyPending();
    }
}
