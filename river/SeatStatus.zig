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

const SeatStatus = @This();

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zriver = wayland.server.zriver;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");
const Output = @import("Output.zig");
const View = @import("View.zig");

seat: *Seat,
seat_status_v1: *zriver.SeatStatusV1,

pub fn init(seat_status: *SeatStatus, seat: *Seat, seat_status_v1: *zriver.SeatStatusV1) void {
    seat_status.* = .{ .seat = seat, .seat_status_v1 = seat_status_v1 };

    seat_status_v1.setHandler(*SeatStatus, handleRequest, handleDestroy, seat_status);

    // Send all info once on bind
    seat_status.sendMode(server.config.modes.items[seat.mode_id].name);
    if (seat.focused_output) |output| seat_status.sendOutput(output, .focused);
    seat_status.sendFocusedView();
}

fn handleRequest(seat_status_v1: *zriver.SeatStatusV1, request: zriver.SeatStatusV1.Request, _: *SeatStatus) void {
    switch (request) {
        .destroy => seat_status_v1.destroy(),
    }
}

fn handleDestroy(_: *zriver.SeatStatusV1, seat_status: *SeatStatus) void {
    const node: *std.SinglyLinkedList(SeatStatus).Node = @fieldParentPtr("data", seat_status);
    seat_status.seat.status_trackers.remove(node);
    util.gpa.destroy(node);
}

pub fn sendOutput(seat_status: SeatStatus, output: *Output, state: enum { focused, unfocused }) void {
    const client = seat_status.seat_status_v1.getClient();
    var it = output.wlr_output.resources.iterator(.forward);
    while (it.next()) |wl_output| {
        if (wl_output.getClient() == client) switch (state) {
            .focused => seat_status.seat_status_v1.sendFocusedOutput(wl_output),
            .unfocused => seat_status.seat_status_v1.sendUnfocusedOutput(wl_output),
        };
    }
}

pub fn sendFocusedView(seat_status: SeatStatus) void {
    const title: [*:0]const u8 = if (seat_status.seat.focused == .view)
        seat_status.seat.focused.view.getTitle() orelse ""
    else
        "";
    seat_status.seat_status_v1.sendFocusedView(title);
}

pub fn sendMode(seat_status: SeatStatus, mode: [*:0]const u8) void {
    if (seat_status.seat_status_v1.getVersion() >= 3) {
        seat_status.seat_status_v1.sendMode(mode);
    }
}
