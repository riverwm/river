// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2023 The River Developers
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

const SceneNodeData = @This();

const build_options = @import("build_options");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const util = @import("util.zig");

const LayerSurface = @import("LayerSurface.zig");
const LockSurface = @import("LockSurface.zig");
const View = @import("View.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");

pub const Data = union(enum) {
    view: *View,
    lock_surface: *LockSurface,
    layer_surface: *LayerSurface,
    override_redirect: if (build_options.xwayland) *XwaylandOverrideRedirect else noreturn,
};

node: *wlr.SceneNode,
data: Data,
destroy: wl.Listener(void) = wl.Listener(void).init(handleDestroy),

pub fn attach(node: *wlr.SceneNode, data: Data) error{OutOfMemory}!void {
    const scene_node_data = try util.gpa.create(SceneNodeData);

    scene_node_data.* = .{
        .node = node,
        .data = data,
    };
    node.data = @intFromPtr(scene_node_data);

    node.events.destroy.add(&scene_node_data.destroy);
}

pub fn fromNode(node: *wlr.SceneNode) ?*SceneNodeData {
    var n = node;
    while (true) {
        if (@as(?*SceneNodeData, @ptrFromInt(n.data))) |scene_node_data| {
            return scene_node_data;
        }
        if (n.parent) |parent_tree| {
            n = &parent_tree.node;
        } else {
            return null;
        }
    }
}

pub fn fromSurface(surface: *wlr.Surface) ?*SceneNodeData {
    if (surface.getRootSurface()) |root_surface| {
        if (@as(?*wlr.SceneNode, @ptrFromInt(root_surface.data))) |node| {
            return fromNode(node);
        }
    }
    return null;
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const scene_node_data = @fieldParentPtr(SceneNodeData, "destroy", listener);

    scene_node_data.destroy.link.remove();
    scene_node_data.node.data = 0;

    util.gpa.destroy(scene_node_data);
}
