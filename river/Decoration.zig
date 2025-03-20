// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2025 The River Developers
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

const Decoration = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Scene = @import("Scene.zig");

const log = std.log.scoped(.wm);

const role: wlr.Surface.Role = .{
    .name = "river_decoration_v1",
    .client_commit = clientCommit,
    .commit = commit,
    .unmap = null,
    .destroy = null,
};

object: *river.DecorationV1,
surface: *wlr.Surface,
tree: *wlr.SceneTree,
surfaces: Scene.SaveableSurfaces,
/// Window.decorations_above/below
link: wl.list.Link,

rendering_requested: struct {
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    sync_next_commit: bool = false,
} = .{},

pub fn create(
    client: *wl.Client,
    version: u32,
    id: u32,
    surface: *wlr.Surface,
    parent: *wlr.SceneTree,
) !*Decoration {
    const decoration_v1 = try river.DecorationV1.create(client, version, id);

    if (!surface.setRole(&role, @ptrCast(decoration_v1), @intFromEnum(river.WindowManagerV1.Error.role))) {
        return error.AlreadyHasRole;
    }
    surface.setRoleObject(@ptrCast(decoration_v1));

    const decoration = try util.gpa.create(Decoration);
    errdefer util.gpa.destroy(decoration);

    const tree = try parent.createSceneTree();
    errdefer tree.node.destroy();

    const surfaces = try Scene.SaveableSurfaces.init(tree);
    _ = try surfaces.tree.createSceneSubsurfaceTree(surface);

    decoration.* = .{
        .object = decoration_v1,
        .surface = surface,
        .tree = tree,
        .surfaces = surfaces,
        .link = undefined,
    };

    decoration_v1.setHandler(*Decoration, handleRequest, handleDestroy, decoration);

    return decoration;
}

fn handleDestroy(_: *river.DecorationV1, decoration: *Decoration) void {
    decoration.tree.node.destroy();

    util.gpa.destroy(decoration);
}

fn handleRequest(
    decoration_v1: *river.DecorationV1,
    request: river.DecorationV1.Request,
    decoration: *Decoration,
) void {
    assert(decoration.object == decoration_v1);
    switch (request) {
        .destroy => decoration_v1.destroy(),
        .set_offset => |args| {
            if (!server.wm.ensureRendering()) return;
            decoration.rendering_requested.offset_x = args.x;
            decoration.rendering_requested.offset_y = args.y;
        },
        .sync_next_commit => {
            if (!server.wm.ensureRendering()) return;
            decoration.rendering_requested.sync_next_commit = true;
        },
    }
}

fn clientCommit(wlr_surface: *wlr.Surface) callconv(.C) void {
    if (wlr_surface.role != &role) return;
    const resource = wlr_surface.role_resource orelse return;
    const decoration: *Decoration = @ptrCast(@alignCast(resource.getUserData()));
    if (decoration.rendering_requested.sync_next_commit) {
        decoration.surfaces.save();
    }
}

fn commit(wlr_surface: *wlr.Surface) callconv(.C) void {
    if (wlr_surface.unmap_commit) {
        wlr_surface.unmap();
    } else if (wlr_surface.hasBuffer()) {
        wlr_surface.map();
    }
}

pub fn updateRenderingFinish(decoration: *Decoration) void {
    const rendering_requested = &decoration.rendering_requested;
    if (rendering_requested.sync_next_commit) {
        rendering_requested.sync_next_commit = false;

        if (!decoration.surfaces.saved.node.enabled) {
            decoration.object.postError(.no_commit,
                \\no wl_surface.commit after sync_next_commit and before update_rendering_finish
            );
        }
    }

    decoration.surfaces.dropSaved();

    decoration.tree.node.setPosition(rendering_requested.offset_x, rendering_requested.offset_y);
}
