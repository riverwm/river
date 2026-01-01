// SPDX-FileCopyrightText: © 2024 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

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
const Tag = @typeInfo(Type).@"union".tag_type.?;

tag: Tag,
object: ?*river.NodeV1 = null,

/// WindowManager.rendering_requested.list
link: wl.list.Link,

pub fn init(node: *WmNode, tag: Tag) void {
    node.* = .{
        .tag = tag,
        .link = undefined,
    };
    node.link.init();
}

pub fn deinit(node: *WmNode) void {
    assert(node.object == null);

    node.link.remove();
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
        .set_position => |args| {
            if (!server.wm.ensureRendering()) return;
            switch (node.get()) {
                .window => |window| {
                    window.rendering_requested.x = args.x;
                    window.rendering_requested.y = args.y;
                },
                .shell_surface => |shell_surface| {
                    shell_surface.rendering_requested.x = args.x;
                    shell_surface.rendering_requested.y = args.y;
                },
            }
        },
        .place_top => {
            if (!server.wm.ensureRendering()) return;
            node.link.remove();
            server.wm.rendering_requested.list.append(node);
        },
        .place_bottom => {
            if (!server.wm.ensureRendering()) return;
            node.link.remove();
            server.wm.rendering_requested.list.prepend(node);
        },
        .place_above => |args| {
            if (!server.wm.ensureRendering()) return;

            const other_data = args.other.getUserData() orelse return;
            const other: *WmNode = @ptrCast(@alignCast(other_data));

            if (other == node) return;

            node.link.remove();
            other.link.insert(&node.link);
        },
        .place_below => |args| {
            if (!server.wm.ensureRendering()) return;

            const other_data = args.other.getUserData() orelse return;
            const other: *WmNode = @ptrCast(@alignCast(other_data));

            if (other == node) return;

            node.link.remove();
            other.link.prev.?.insert(&node.link);
        },
    }
}
