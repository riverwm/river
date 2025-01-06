// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2024 The River Developers
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

const WmNode = @This();

const std = @import("std");
const assert = std.debug.assert;
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Window = @import("Window.zig");
const ShellSurface = @import("ShellSurface.zig");

const Type = union(enum) {
    window: *Window,
    shell_surface: *ShellSurface,
};
const Tag = @typeInfo(Type).Union.tag_type.?;

tag: Tag,
object: ?*river.NodeV1 = null,

/// WindowManager.uncommitted.render_list
link_uncommitted: wl.list.Link,
/// WindowManager.committed.render_list
link_committed: wl.list.Link,
/// WindowManager.inflight.render_list
link_inflight: wl.list.Link,

pub fn init(node: *WmNode, tag: Tag) void {
    node.* = .{
        .tag = tag,
        .link_uncommitted = undefined,
        .link_committed = undefined,
        .link_inflight = undefined,
    };
    node.link_uncommitted.init();
    node.link_committed.init();
    node.link_inflight.init();
}

pub fn deinit(node: *WmNode) void {
    assert(node.object == null);

    node.link_uncommitted.remove();
    node.link_committed.remove();
    node.link_inflight.remove();
}

pub fn get(node: *WmNode) Type {
    return switch (node.tag) {
        .window => .{ .window = @fieldParentPtr("node", node) },
        .shell_surface => .{ .shell_surface = @fieldParentPtr("node", node) },
    };
}

pub fn createObject(node: *WmNode, client: *wl.Client, version: u32, id: u32) void {
    assert(node.object == null);
    const node_v1 = river.NodeV1.create(client, version, id) catch {
        std.log.err("out of memory", .{});
        client.postNoMemory();
        return;
    };
    node_v1.setHandler(*WmNode, handleRequest, handleDestroy, node);
    node.object = node_v1;
}

pub fn makeInert(node: *WmNode) void {
    if (node.object) |node_v1| {
        node_v1.setHandler(?*anyopaque, handleRequestInert, null, null);
        node.object = null;
    }
}

fn handleRequestInert(
    node_v1: *river.NodeV1,
    request: river.NodeV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) node_v1.destroy();
}

fn handleDestroy(_: *river.NodeV1, node: *WmNode) void {
    node.object = null;
}

fn handleRequest(
    node_v1: *river.NodeV1,
    request: river.NodeV1.Request,
    node: *WmNode,
) void {
    assert(node.object == node_v1);
    switch (request) {
        .destroy => {
            node_v1.destroy();
        },
        .set_position => |args| switch (node.get()) {
            .window => |window| {
                window.uncommitted.position = .{
                    .x = args.x,
                    .y = args.y,
                };
            },
            .shell_surface => |shell_surface| {
                shell_surface.uncommitted.x = args.x;
                shell_surface.uncommitted.y = args.y;
            },
        },
        .place_top => {
            node.link_uncommitted.remove();
            server.wm.uncommitted.render_list.append(node);
        },
        .place_bottom => {
            node.link_uncommitted.remove();
            server.wm.uncommitted.render_list.prepend(node);
        },
        .place_above => |args| {
            const other_data = args.other.getUserData() orelse return;
            const other: *WmNode = @ptrCast(@alignCast(other_data));

            if (other == node) return;

            node.link_uncommitted.remove();
            other.link_uncommitted.insert(&node.link_uncommitted);
        },
        .place_below => |args| {
            const other_data = args.other.getUserData() orelse return;
            const other: *WmNode = @ptrCast(@alignCast(other_data));

            if (other == node) return;

            node.link_uncommitted.remove();
            other.link_uncommitted.prev.?.insert(&node.link_uncommitted);
        },
    }
}
