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

/// Set opacity on currently focused view.
pub fn setOpacity(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    if (seat.focused == .view) {
        const view = seat.focused.view;

        var opacity = op: {
            if (args[1][0] == '+') {
                break :op view.opacity + try std.fmt.parseFloat(f32, args[1][1..]);
            } else if (args[1][0] == '-') {
                break :op view.opacity - try std.fmt.parseFloat(f32, args[1][1..]);
            } else {
                break :op try std.fmt.parseFloat(f32, args[1]);
            }
        };
        opacity = @minimum(opacity, server.config.max_opacity);
        opacity = @maximum(opacity, server.config.min_opacity);
        view.opacity = opacity;
        // Force render
        var it = server.root.outputs.first;
        while (it) |node| : (it = node.next) node.data.damage.addWhole();
    }
}
