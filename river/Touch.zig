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

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;

const server = &@import("main.zig").server;

const Cursor = @import("Cursor.zig");
const Seat = @import("Seat.zig");

const log = std.log.scoped(.touch);

seat: *Seat,
wlr_cursor: *wlr.Cursor,

touch_up: wl.Listener(*wlr.Touch.event.Up) =
    wl.Listener(*wlr.Touch.event.Up).init(handleTouchUp),
touch_down: wl.Listener(*wlr.Touch.event.Down) =
    wl.Listener(*wlr.Touch.event.Down).init(handleTouchDown),
touch_motion: wl.Listener(*wlr.Touch.event.Motion) =
    wl.Listener(*wlr.Touch.event.Motion).init(handleTouchMotion),

pub fn init(self: *Self, seat: *Seat) !void {
    const wlr_cursor = try wlr.Cursor.create();
    errdefer wlr_cursor.destroy();
    wlr_cursor.attachOutputLayout(server.root.output_layout);

    self.* = .{
        .seat = seat,
        .wlr_cursor = wlr_cursor,
    };

    wlr_cursor.events.touch_up.add(&self.touch_up);
    wlr_cursor.events.touch_down.add(&self.touch_down);
    wlr_cursor.events.touch_motion.add(&self.touch_motion);
}

pub fn deinit(self: *Self) void {
    self.wlr_cursor.destroy();
}

fn handleTouchMotion(
    listener: *wl.Listener(*wlr.Touch.event.Motion),
    event: *wlr.Touch.event.Motion,
) void {
    const self = @fieldParentPtr(Self, "touch_motion", listener);

    self.seat.handleActivity();

    var lx: f64 = undefined;
    var ly: f64 = undefined;
    self.wlr_cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);

    if (Cursor.surfaceAtPosition(lx, ly)) |result| {
        _ = self.seat.wlr_seat.touchNotifyMotion(event.time_msec, event.touch_id, result.sx, result.sy);
    }
}

fn handleTouchUp(
    listener: *wl.Listener(*wlr.Touch.event.Up),
    event: *wlr.Touch.event.Up,
) void {
    const self = @fieldParentPtr(Self, "touch_up", listener);

    self.seat.handleActivity();

    _ = self.seat.wlr_seat.touchNotifyUp(event.time_msec, event.touch_id);
}

fn handleTouchDown(
    listener: *wl.Listener(*wlr.Touch.event.Down),
    event: *wlr.Touch.event.Down,
) void {
    const self = @fieldParentPtr(Self, "touch_down", listener);

    self.seat.handleActivity();

    var lx: f64 = undefined;
    var ly: f64 = undefined;
    self.wlr_cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);

    if (Cursor.surfaceAtPosition(lx, ly)) |result| {
        switch (result.parent) {
            .view => |view| {
                self.seat.focusOutput(view.output);
                self.seat.focus(view);
                server.root.startTransaction();
            },
            .layer_surface => {},
            .xwayland_unmanaged => assert(build_options.xwayland),
        }
        _ = self.seat.wlr_seat.touchNotifyDown(result.surface, event.time_msec, event.touch_id, result.sx, result.sy);
    }

    self.seat.cursor.hide();
}
