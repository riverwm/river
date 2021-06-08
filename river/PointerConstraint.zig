// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 The River Developers
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
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const pixman = @import("pixman");

const log = @import("log.zig");
const util = @import("util.zig");

const Cursor = @import("Cursor.zig");
const Seat = @import("Seat.zig");
const View = @import("View.zig");

constraint: *wlr.PointerConstraintV1,
cursor: *Cursor,

destroy: wl.Listener(*wlr.PointerConstraintV1) = wl.Listener(*wlr.PointerConstraintV1).init(handleDestroy),
set_region: wl.Listener(void) = wl.Listener(void).init(handleSetRegion),

pub fn init(self: *Self, constraint: *wlr.PointerConstraintV1) void {
    const seat = @intToPtr(*Seat, constraint.seat.data);
    self.* = .{
        .constraint = constraint,
        .cursor = &seat.cursor,
    };

    self.constraint.data = @ptrToInt(self);

    self.constraint.events.destroy.add(&self.destroy);
    self.constraint.events.set_region.add(&self.set_region);

    if (seat.focused == .view and seat.focused.view.surface == self.constraint.surface) {
        self.setAsActive();
    }
}

pub fn setAsActive(self: *Self) void {
    if (self.cursor.constraint == self.constraint) return;

    if (self.cursor.constraint) |constraint| {
        constraint.sendDeactivated();
    }

    self.cursor.constraint = self.constraint;

    if (self.constraint.current.region.notEmpty()) {
        _ = self.constraint.region.intersect(&self.constraint.surface.input_region, &self.constraint.current.region);
    } else {
        _ = self.constraint.region.copy(&self.constraint.surface.input_region);
    }
    self.constrainToRegion();

    self.constraint.sendActivated();
}

fn constrainToRegion(self: *Self) void {
    if (self.cursor.constraint != self.constraint) return;
    if (View.fromWlrSurface(self.constraint.surface)) |view| {
        const cx = @floatToInt(c_int, self.cursor.wlr_cursor.x) - @intCast(c_int, view.current.box.x);
        const cy = @floatToInt(c_int, self.cursor.wlr_cursor.y) - @intCast(c_int, view.current.box.y);

        var box: pixman.Box32 = undefined;

        if (!self.constraint.region.containsPoint(cx, cy, &box)) {
            const rects = self.constraint.region.rectangles();

            if (rects.len > 0) {
                const new_cx = @intToFloat(f64, view.current.box.x + rects[0].x1 + @divFloor(rects[0].x2, 2));
                const new_cy = @intToFloat(f64, view.current.box.y + rects[0].y1 + @divFloor(rects[0].y2, 2));

                self.cursor.wlr_cursor.warpClosest(null, new_cx, new_cy);
            }
        }
    }
}

fn handleDestroy(listener: *wl.Listener(*wlr.PointerConstraintV1), constraint: *wlr.PointerConstraintV1) void {
    const self = @fieldParentPtr(Self, "destroy", listener);

    self.destroy.link.remove();
    self.set_region.link.remove();

    if (self.cursor.constraint == self.constraint) {
        warpToHint(self.cursor);

        self.cursor.constraint = null;
    }

    util.gpa.destroy(self);
}

fn handleSetRegion(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "set_region", listener);
    self.constrainToRegion();
}

pub fn warpToHint(cursor: *Cursor) void {
    if (cursor.constraint) |constraint| {
        if (constraint.current.committed.cursor_hint) {
            if (View.fromWlrSurface(constraint.surface)) |view| {
                const cx = constraint.current.cursor_hint.x + @intToFloat(f64, view.current.box.x);
                const cy = constraint.current.cursor_hint.y + @intToFloat(f64, view.current.box.y);

                _ = cursor.wlr_cursor.warp(null, cx, cy);
            }
        }
    }
}
