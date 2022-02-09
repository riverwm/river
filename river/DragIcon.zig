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
const Subsurface = @import("Subsurface.zig");

seat: *Seat,
wlr_drag_icon: *wlr.Drag.Icon,

// Always active
destroy: wl.Listener(*wlr.Drag.Icon) = wl.Listener(*wlr.Drag.Icon).init(handleDestroy),
map: wl.Listener(*wlr.Drag.Icon) = wl.Listener(*wlr.Drag.Icon).init(handleMap),
unmap: wl.Listener(*wlr.Drag.Icon) = wl.Listener(*wlr.Drag.Icon).init(handleUnmap),
new_subsurface: wl.Listener(*wlr.Subsurface) = wl.Listener(*wlr.Subsurface).init(handleNewSubsurface),

// Only active while mapped
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),

pub fn init(drag_icon: *DragIcon, seat: *Seat, wlr_drag_icon: *wlr.Drag.Icon) void {
    drag_icon.* = .{ .seat = seat, .wlr_drag_icon = wlr_drag_icon };

    wlr_drag_icon.events.destroy.add(&drag_icon.destroy);
    wlr_drag_icon.events.map.add(&drag_icon.map);
    wlr_drag_icon.events.unmap.add(&drag_icon.unmap);
    wlr_drag_icon.surface.events.new_subsurface.add(&drag_icon.new_subsurface);

    if (wlr_drag_icon.mapped) handleMap(&drag_icon.map, wlr_drag_icon);

    Subsurface.handleExisting(wlr_drag_icon.surface, .{ .drag_icon = drag_icon });
}

fn handleDestroy(listener: *wl.Listener(*wlr.Drag.Icon), wlr_drag_icon: *wlr.Drag.Icon) void {
    const drag_icon = @fieldParentPtr(DragIcon, "destroy", listener);

    const node = @fieldParentPtr(std.SinglyLinkedList(DragIcon).Node, "data", drag_icon);
    server.root.drag_icons.remove(node);

    drag_icon.destroy.link.remove();
    drag_icon.map.link.remove();
    drag_icon.unmap.link.remove();
    drag_icon.new_subsurface.link.remove();

    Subsurface.destroySubsurfaces(wlr_drag_icon.surface);

    util.gpa.destroy(node);
}

fn handleMap(listener: *wl.Listener(*wlr.Drag.Icon), wlr_drag_icon: *wlr.Drag.Icon) void {
    const drag_icon = @fieldParentPtr(DragIcon, "map", listener);

    wlr_drag_icon.surface.events.commit.add(&drag_icon.commit);
    var it = server.root.outputs.first;
    while (it) |node| : (it = node.next) node.data.damage.?.addWhole();
}

fn handleUnmap(listener: *wl.Listener(*wlr.Drag.Icon), _: *wlr.Drag.Icon) void {
    const drag_icon = @fieldParentPtr(DragIcon, "unmap", listener);

    drag_icon.commit.link.remove();
    var it = server.root.outputs.first;
    while (it) |node| : (it = node.next) node.data.damage.?.addWhole();
}

fn handleCommit(_: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    var it = server.root.outputs.first;
    while (it) |node| : (it = node.next) node.data.damage.?.addWhole();
}

fn handleNewSubsurface(listener: *wl.Listener(*wlr.Subsurface), wlr_subsurface: *wlr.Subsurface) void {
    const drag_icon = @fieldParentPtr(DragIcon, "new_subsurface", listener);

    Subsurface.create(wlr_subsurface, .{ .drag_icon = drag_icon });
}
