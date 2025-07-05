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

const ShellSurface = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Scene = @import("Scene.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const WmNode = @import("WmNode.zig");

const log = std.log.scoped(.wm);

const role: wlr.Surface.Role = .{
    .name = "river_shell_surface_v1",
    .client_commit = clientCommit,
    .commit = commit,
    .unmap = null,
    .destroy = null,
};

object: *river.ShellSurfaceV1,
surface: *wlr.Surface,
tree: *wlr.SceneTree,
surfaces: Scene.SaveableSurfaces,
node: WmNode,

rendering_requested: struct {
    x: i32 = 0,
    y: i32 = 0,
    sync_next_commit: bool = false,
} = .{},

pub fn create(
    client: *wl.Client,
    version: u32,
    id: u32,
    surface: *wlr.Surface,
) !void {
    log.debug("new river_shell_surface_v1", .{});

    const shell_surface_v1 = try river.ShellSurfaceV1.create(client, version, id);

    if (!surface.setRole(&role, @ptrCast(shell_surface_v1), @intFromEnum(river.WindowManagerV1.Error.role))) {
        return;
    }
    surface.setRoleObject(@ptrCast(shell_surface_v1));

    const shell_surface = try util.gpa.create(ShellSurface);
    errdefer util.gpa.destroy(shell_surface);

    const tree = try server.scene.hidden_tree.createSceneTree();
    errdefer tree.node.destroy();

    const surfaces = try Scene.SaveableSurfaces.init(tree);
    _ = try surfaces.tree.createSceneSubsurfaceTree(surface);

    try SceneNodeData.attach(&tree.node, .{ .shell_surface = shell_surface });

    shell_surface.* = .{
        .object = shell_surface_v1,
        .surface = surface,
        .tree = tree,
        .surfaces = surfaces,
        .node = undefined,
    };
    shell_surface.node.init(.shell_surface);
    server.wm.rendering_requested.list.append(&shell_surface.node);

    shell_surface_v1.setHandler(*ShellSurface, handleRequest, handleDestroy, shell_surface);
}

fn handleDestroy(_: *river.ShellSurfaceV1, shell_surface: *ShellSurface) void {
    shell_surface.surface.unmap();

    shell_surface.node.makeInert();
    shell_surface.node.deinit();

    shell_surface.tree.node.destroy();

    util.gpa.destroy(shell_surface);
}

fn handleRequest(
    shell_surface_v1: *river.ShellSurfaceV1,
    request: river.ShellSurfaceV1.Request,
    shell_surface: *ShellSurface,
) void {
    assert(shell_surface.object == shell_surface_v1);
    switch (request) {
        .destroy => shell_surface_v1.destroy(),
        .get_node => |args| {
            if (shell_surface.node.object != null) {
                shell_surface_v1.postError(.node_exists, "shell surface already has a node object");
                return;
            }
            shell_surface.node.createObject(
                shell_surface_v1.getClient(),
                shell_surface_v1.getVersion(),
                args.id,
            );
        },
        .sync_next_commit => {
            if (!server.wm.ensureRendering()) return;
            shell_surface.rendering_requested.sync_next_commit = true;
        },
    }
}

fn clientCommit(wlr_surface: *wlr.Surface) callconv(.C) void {
    if (wlr_surface.role != &role) return;
    const resource = wlr_surface.role_resource orelse return;

    const shell_surface: *ShellSurface = @ptrCast(@alignCast(resource.getUserData()));

    if (shell_surface.rendering_requested.sync_next_commit) {
        shell_surface.surfaces.save();
    }
}

fn commit(wlr_surface: *wlr.Surface) callconv(.C) void {
    if (wlr_surface.hasBuffer()) {
        wlr_surface.map();
    }
}

pub fn renderFinish(shell_surface: *ShellSurface) void {
    const rendering_requested = &shell_surface.rendering_requested;
    if (rendering_requested.sync_next_commit) {
        rendering_requested.sync_next_commit = false;

        if (!shell_surface.surfaces.saved.node.enabled) {
            shell_surface.object.postError(.no_commit,
                \\no wl_surface.commit after sync_next_commit and before update_rendering_finish
            );
        }
    }

    shell_surface.surfaces.dropSaved();

    shell_surface.tree.node.setPosition(rendering_requested.x, rendering_requested.y);
}
