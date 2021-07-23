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
const Seat = @import("../Seat.zig");

/// Make the focused view float or stop floating, depending on its current
/// state.
pub fn toggleFloat(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len > 1) return Error.TooManyArguments;

    if (seat.focused == .view) {
        const view = seat.focused.view;

        // If views are unarranged, don't allow changing the views float status.
        // It would just lead to confusing because this state would not be
        // visible immediately, only after a layout is connected.
        if (view.output.current.layout == null)
            return;

        // Don't float fullscreen views
        if (view.pending.fullscreen) return;

        view.pending.float = !view.pending.float;
        view.applyPending();
    }
}
