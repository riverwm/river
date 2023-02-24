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

/// Make the focused view float or stop floating, depending on its current
/// state.
pub fn toggleFloat(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len > 1) return Error.TooManyArguments;

    if (seat.focused == .view) {
        const view = seat.focused.view;

        // If views are unarranged, don't allow changing the views float status.
        // It would just lead to confusing because this state would not be
        // visible immediately, only after a layout is connected.
        if (view.pending.output == null or view.pending.output.?.layout == null) return;

        // Don't float fullscreen views
        if (view.pending.fullscreen) return;

        view.pending.float = !view.pending.float;
        server.root.applyPending();
    }
}
