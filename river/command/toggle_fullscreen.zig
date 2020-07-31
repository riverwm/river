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

const Box = @import("../Box.zig");
const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

/// Toggle fullscreen state of the currently focused view
pub fn toggleFullscreen(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len > 1) return Error.TooManyArguments;

    if (seat.focused == .view) {
        const view = seat.focused.view;

        // Don't modify views which are the target of a cursor action
        if (seat.input_manager.isCursorActionTarget(view)) return;

        view.setFullscreen(!view.pending.fullscreen);

        if (view.pending.fullscreen) {
            const output = view.output;
            view.pending.box = Box.fromWlrBox(
                c.wlr_output_layout_get_box(output.root.wlr_output_layout, output.wlr_output).*,
            );
            view.configure();
        } else if (view.pending.float) {
            // If transitioning from fullscreen -> float, return to the saved
            // floating dimensions.
            view.pending.box = view.float_box;
            view.configure();
        } else {
            // Transitioning to layout, arrange and start a transaction
            view.output.root.arrange();
        }
    }
}
