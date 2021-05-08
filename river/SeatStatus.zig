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

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const util = @import("util.zig");

const Seat = @import("Seat.zig");
const Output = @import("Output.zig");
const View = @import("View.zig");

seat: *Seat,
seat_status: *river.SeatStatusV1,

pub fn init(self: *Self, seat: *Seat, seat_status: *river.SeatStatusV1) void {
    self.* = .{ .seat = seat, .seat_status = seat_status };

    seat_status.setHandler(*Self, handleRequest, handleDestroy, self);

    // Send focused output/view once on bind
    self.sendOutput(.focused);
    self.sendFocusedView();
}

fn handleRequest(seat_status: *river.SeatStatusV1, request: river.SeatStatusV1.Request, self: *Self) void {
    switch (request) {
        .destroy => seat_status.destroy(),
    }
}

fn handleDestroy(seat_status: *river.SeatStatusV1, self: *Self) void {
    const node = @fieldParentPtr(std.SinglyLinkedList(Self).Node, "data", self);
    self.seat.status_trackers.remove(node);
    util.gpa.destroy(node);
}

pub fn sendOutput(self: Self, state: enum { focused, unfocused }) void {
    const client = self.seat_status.getClient();
    var it = self.seat.focused_output.wlr_output.resources.iterator(.forward);
    while (it.next()) |wl_output| {
        if (wl_output.getClient() == client) switch (state) {
            .focused => self.seat_status.sendFocusedOutput(wl_output),
            .unfocused => self.seat_status.sendUnfocusedOutput(wl_output),
        };
    }
}

pub fn sendFocusedView(self: Self) void {
    const title: [*:0]const u8 = if (self.seat.focused == .view)
        self.seat.focused.view.getTitle() orelse ""
    else
        "";
    self.seat_status.sendFocusedView(title);
}
