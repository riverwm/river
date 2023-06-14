// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2023 The River Developers
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
const mem = std.mem;

const server = &@import("../main.zig").server;

const View = @import("../View.zig");
const Seat = @import("../Seat.zig");
const Error = @import("../command.zig").Error;

pub fn focusViewById(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    if (seat.focused != .view) return;
    if (seat.focused.view.pending.fullscreen) return;

    const view = viewById(args[1]) orelse return;
    const output = view.pending.output orelse return;
    if (output.pending.tags != view.pending.tags) {
        output.previous_tags = output.pending.tags;
        output.pending.tags = view.pending.tags;
    }
    if (seat.focused_output == null or seat.focused_output.? != output) {
        seat.focusOutput(output);
    }
    seat.focus(view);
    server.root.applyPending();
}

fn viewById(id: []const u8) ?*View {
    var it = server.root.views.iterator(.forward);
    while (it.next()) |view| {
        if (mem.eql(u8, id, view.id)) return view;
    }
    return null;
}
