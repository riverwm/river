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

const SceneNodeData = @import("SceneNodeData.zig");

wlr_drag_icon: *wlr.Drag.Icon,

tree: *wlr.SceneTree,
surface: *wlr.SceneTree,

destroy: wl.Listener(*wlr.Drag.Icon) = wl.Listener(*wlr.Drag.Icon).init(handleDestroy),
map: wl.Listener(*wlr.Drag.Icon) = wl.Listener(*wlr.Drag.Icon).init(handleMap),
unmap: wl.Listener(*wlr.Drag.Icon) = wl.Listener(*wlr.Drag.Icon).init(handleUnmap),
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),

pub fn create(wlr_drag_icon: *wlr.Drag.Icon) error{OutOfMemory}!void {
    const tree = try server.root.drag_icons.createSceneTree();
    errdefer tree.node.destroy();

    const drag_icon = try util.gpa.create(DragIcon);
    errdefer util.gpa.destroy(drag_icon);

    drag_icon.* = .{
        .wlr_drag_icon = wlr_drag_icon,
        .tree = tree,
        .surface = try tree.createSceneSubsurfaceTree(wlr_drag_icon.surface),
    };
    tree.node.data = @intFromPtr(drag_icon);

    tree.node.setEnabled(wlr_drag_icon.mapped);

    wlr_drag_icon.events.destroy.add(&drag_icon.destroy);
    wlr_drag_icon.events.map.add(&drag_icon.map);
    wlr_drag_icon.events.unmap.add(&drag_icon.unmap);
    wlr_drag_icon.surface.events.commit.add(&drag_icon.commit);
}

fn handleDestroy(listener: *wl.Listener(*wlr.Drag.Icon), _: *wlr.Drag.Icon) void {
    const drag_icon = @fieldParentPtr(DragIcon, "destroy", listener);

    drag_icon.tree.node.destroy();

    drag_icon.destroy.link.remove();
    drag_icon.map.link.remove();
    drag_icon.unmap.link.remove();
    drag_icon.commit.link.remove();

    util.gpa.destroy(drag_icon);
}

fn handleMap(listener: *wl.Listener(*wlr.Drag.Icon), _: *wlr.Drag.Icon) void {
    const drag_icon = @fieldParentPtr(DragIcon, "map", listener);

    drag_icon.tree.node.setEnabled(true);
}

fn handleUnmap(listener: *wl.Listener(*wlr.Drag.Icon), _: *wlr.Drag.Icon) void {
    const drag_icon = @fieldParentPtr(DragIcon, "unmap", listener);

    drag_icon.tree.node.setEnabled(false);
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), surface: *wlr.Surface) void {
    const drag_icon = @fieldParentPtr(DragIcon, "commit", listener);

    drag_icon.surface.node.setPosition(
        drag_icon.surface.node.x + surface.current.dx,
        drag_icon.surface.node.y + surface.current.dy,
    );
}
