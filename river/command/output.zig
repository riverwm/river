// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 The River Developers
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

const wlr = @import("wlroots");

const server = &@import("../main.zig").server;

const Direction = @import("../command.zig").Direction;
const PhysicalDirectionDirection = @import("../command.zig").PhysicalDirection;
const Error = @import("../command.zig").Error;
const Output = @import("../Output.zig");
const Seat = @import("../Seat.zig");

pub fn focusOutput(
    _: std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    // If the noop output is focused, there are no other outputs to switch to
    if (seat.focused_output == &server.root.noop_output) {
        std.debug.assert(server.root.outputs.len == 0);
        return;
    }

    seat.focusOutput((try getOutput(seat, args[1])) orelse return);
    seat.focus(null);
    server.root.startTransaction();
}

pub fn sendToOutput(
    _: std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    // If the noop output is focused, there is nowhere to send the view
    if (seat.focused_output == &server.root.noop_output) {
        std.debug.assert(server.root.outputs.len == 0);
        return;
    }

    if (seat.focused == .view) {
        const destination_output = (try getOutput(seat, args[1])) orelse return;
        // If the view is already on destination_output, do nothing
        if (seat.focused.view.output == destination_output) return;
        seat.focused.view.sendToOutput(destination_output);

        // Handle the change and focus whatever's next in the focus stack
        seat.focus(null);
        seat.focused_output.arrangeViews();
        destination_output.arrangeViews();
        server.root.startTransaction();
    }
}

/// Find an output adjacent to the currently focused based on either logical or
/// spacial direction
fn getOutput(seat: *Seat, str: []const u8) !?*Output {
    if (std.meta.stringToEnum(Direction, str)) |direction| { // Logical direction
        // Return the next/prev output in the list if there is one, else wrap
        const focused_node = @fieldParentPtr(std.TailQueue(Output).Node, "data", seat.focused_output);
        return switch (direction) {
            .next => if (focused_node.next) |node| &node.data else &server.root.outputs.first.?.data,
            .previous => if (focused_node.prev) |node| &node.data else &server.root.outputs.last.?.data,
        };
    } else if (std.meta.stringToEnum(wlr.OutputLayout.Direction, str)) |direction| { // Spacial direction
        const focus_box = server.root.output_layout.getBox(seat.focused_output.wlr_output) orelse return null;
        const wlr_output = server.root.output_layout.adjacentOutput(
            direction,
            seat.focused_output.wlr_output,
            @intToFloat(f64, focus_box.x + @divFloor(focus_box.width, 2)),
            @intToFloat(f64, focus_box.y + @divFloor(focus_box.height, 2)),
        ) orelse return null;
        return @intToPtr(*Output, wlr_output.data);
    } else {
        // Check if an output matches by name
        var it = server.root.outputs.first;
        while (it) |node| : (it = node.next) {
            if (std.mem.eql(u8, std.mem.sliceTo(node.data.wlr_output.name, 0), str)) {
                return &node.data;
            }
        }
        return Error.InvalidDirection;
    }
}
