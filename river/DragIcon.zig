// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020-2021 The River Developers
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

const DragIcon = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");

seat: *Seat,
wlr_drag_icon: *wlr.Drag.Icon,

// Accumulated x/y surface offset from the cursor/touch point position.
sx: i32 = 0,
sy: i32 = 0,

// Always active
destroy: wl.Listener(*wlr.Drag.Icon) = wl.Listener(*wlr.Drag.Icon).init(handleDestroy),
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),

pub fn init(drag_icon: *DragIcon, seat: *Seat, wlr_drag_icon: *wlr.Drag.Icon) void {
    drag_icon.* = .{ .seat = seat, .wlr_drag_icon = wlr_drag_icon };

    wlr_drag_icon.events.destroy.add(&drag_icon.destroy);
    wlr_drag_icon.surface.events.commit.add(&drag_icon.commit);
}

fn handleDestroy(listener: *wl.Listener(*wlr.Drag.Icon), _: *wlr.Drag.Icon) void {
    const drag_icon = @fieldParentPtr(DragIcon, "destroy", listener);

    drag_icon.seat.drag_icon = null;

    drag_icon.destroy.link.remove();
    drag_icon.commit.link.remove();

    util.gpa.destroy(drag_icon);
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), surface: *wlr.Surface) void {
    const drag_icon = @fieldParentPtr(DragIcon, "commit", listener);

    drag_icon.sx += surface.current.dx;
    drag_icon.sy += surface.current.dy;
}
