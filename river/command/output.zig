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
const assert = std.debug.assert;
const mem = std.mem;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const flags = @import("flags");

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Direction = @import("../command.zig").Direction;
const PhysicalDirectionDirection = @import("../command.zig").PhysicalDirection;
const Error = @import("../command.zig").Error;
const Output = @import("../Output.zig");
const Seat = @import("../Seat.zig");

pub fn focusOutput(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    // If the fallback pseudo-output is focused, there are no other outputs to switch to
    if (seat.focused_output == null) {
        assert(server.root.active_outputs.empty());
        return;
    }

    seat.focusOutput((try getOutput(seat, args[1])) orelse return);
    server.root.applyPending();
}

pub fn sendToOutput(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    const result = flags.parser([:0]const u8, &.{
        .{ .name = "current-tags", .kind = .boolean },
    }).parse(args[1..]) catch {
        return error.InvalidOption;
    };
    if (result.args.len < 1) return Error.NotEnoughArguments;
    if (result.args.len > 1) return Error.TooManyArguments;

    // If the fallback pseudo-output is focused, there is nowhere to send the view
    if (seat.focused_output == null) {
        assert(server.root.active_outputs.empty());
        return;
    }

    if (seat.focused == .view) {
        const destination_output = (try getOutput(seat, result.args[0])) orelse return;

        // If the view is already on destination_output, do nothing
        if (seat.focused.view.pending.output == destination_output) return;

        if (result.flags.@"current-tags") {
            seat.focused.view.pending.tags = destination_output.pending.tags;
        }

        seat.focused.view.setPendingOutput(destination_output);

        // When explicitly sending a view to an output, the user likely
        // does not expect a previously evacuated view moved back to a
        // re-connecting output.
        if (seat.focused.view.output_before_evac) |name| {
            util.gpa.free(name);
            seat.focused.view.output_before_evac = null;
        }

        server.root.applyPending();
    }
}

/// Find an output adjacent to the currently focused based on either logical or
/// spacial direction
fn getOutput(seat: *Seat, str: []const u8) !?*Output {
    if (std.meta.stringToEnum(Direction, str)) |direction| { // Logical direction
        // Return the next/prev output in the list
        var link = &seat.focused_output.?.active_link;
        link = switch (direction) {
            .next => link.next.?,
            .previous => link.prev.?,
        };
        // Wrap around list head
        if (link == &server.root.active_outputs.link) {
            link = switch (direction) {
                .next => link.next.?,
                .previous => link.prev.?,
            };
        }
        return @as(*Output, @fieldParentPtr("active_link", link));
    } else if (std.meta.stringToEnum(wlr.OutputLayout.Direction, str)) |direction| { // Spacial direction
        var focus_box: wlr.Box = undefined;
        server.root.output_layout.getBox(seat.focused_output.?.wlr_output, &focus_box);
        if (focus_box.empty()) return null;

        const wlr_output = server.root.output_layout.adjacentOutput(
            direction,
            seat.focused_output.?.wlr_output,
            @floatFromInt(focus_box.x + @divTrunc(focus_box.width, 2)),
            @floatFromInt(focus_box.y + @divTrunc(focus_box.height, 2)),
        ) orelse return null;
        return @as(*Output, @ptrFromInt(wlr_output.data));
    } else {
        // Check if an output matches by name
        var it = server.root.active_outputs.iterator(.forward);
        while (it.next()) |output| {
            if (mem.eql(u8, mem.sliceTo(output.wlr_output.name, 0), str)) {
                return output;
            }
        }
        return Error.InvalidOutputIndicator;
    }
}
