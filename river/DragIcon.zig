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

const Cursor = @import("Cursor.zig");
const SceneNodeData = @import("SceneNodeData.zig");

wlr_drag_icon: *wlr.Drag.Icon,
scene_drag_icon: *wlr.SceneTree,

destroy: wl.Listener(*wlr.Drag.Icon) = wl.Listener(*wlr.Drag.Icon).init(handleDestroy),

pub fn create(wlr_drag_icon: *wlr.Drag.Icon, cursor: *Cursor) error{OutOfMemory}!void {
    const scene_drag_icon = try server.root.drag_icons.createSceneDragIcon(wlr_drag_icon);
    errdefer scene_drag_icon.node.destroy();

    const drag_icon = try util.gpa.create(DragIcon);
    errdefer util.gpa.destroy(drag_icon);

    drag_icon.* = .{
        .wlr_drag_icon = wlr_drag_icon,
        .scene_drag_icon = scene_drag_icon,
    };
    scene_drag_icon.node.data = @intFromPtr(drag_icon);

    drag_icon.updatePosition(cursor);

    wlr_drag_icon.events.destroy.add(&drag_icon.destroy);
}

pub fn updatePosition(drag_icon: *DragIcon, cursor: *Cursor) void {
    switch (drag_icon.wlr_drag_icon.drag.grab_type) {
        .keyboard => unreachable,
        .keyboard_pointer => {
            drag_icon.scene_drag_icon.node.setPosition(
                @intFromFloat(cursor.wlr_cursor.x),
                @intFromFloat(cursor.wlr_cursor.y),
            );
        },
        .keyboard_touch => {
            const touch_id = drag_icon.wlr_drag_icon.drag.touch_id;
            if (cursor.touch_points.get(touch_id)) |point| {
                drag_icon.scene_drag_icon.node.setPosition(
                    @intFromFloat(point.lx),
                    @intFromFloat(point.ly),
                );
            }
        },
    }
}

fn handleDestroy(listener: *wl.Listener(*wlr.Drag.Icon), _: *wlr.Drag.Icon) void {
    const drag_icon = @fieldParentPtr(DragIcon, "destroy", listener);

    drag_icon.destroy.link.remove();

    util.gpa.destroy(drag_icon);
}
