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
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const util = @import("util.zig");

const Seat = @import("Seat.zig");

seat: *Seat,
wlr_drag_icon: *wlr.Drag.Icon,

destroy: wl.Listener(*wlr.Drag.Icon) = wl.Listener(*wlr.Drag.Icon).init(handleDestroy),

pub fn init(self: *Self, seat: *Seat, wlr_drag_icon: *wlr.Drag.Icon) void {
    self.* = .{ .seat = seat, .wlr_drag_icon = wlr_drag_icon };
    wlr_drag_icon.events.destroy.add(&self.destroy);
}

fn handleDestroy(listener: *wl.Listener(*wlr.Drag.Icon), wlr_drag_icon: *wlr.Drag.Icon) void {
    const self = @fieldParentPtr(Self, "destroy", listener);
    const root = &self.seat.input_manager.server.root;
    const node = @fieldParentPtr(std.SinglyLinkedList(Self).Node, "data", self);
    root.drag_icons.remove(node);
    util.gpa.destroy(node);
}
