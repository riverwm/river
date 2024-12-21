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

const Scene = @This();

const build_options = @import("build_options");
const wlr = @import("wlroots");

const SceneNodeData = @import("SceneNodeData.zig");

wlr_scene: *wlr.Scene,
/// All windows, status bars, drowdown menus, etc. that can recieve pointer events and similar.
interactive_tree: *wlr.SceneTree,
/// Drag icons, which cannot recieve e.g. pointer events and are therefore kept
/// in a separate tree from the interactive tree.
drag_icons: *wlr.SceneTree,
/// Always disabled, used for staging changes
/// TODO can this be refactored away?
hidden_tree: *wlr.SceneTree,
/// Direct child of interactive_tree, disabled when the session is locked
normal_tree: *wlr.SceneTree,
/// Direct child of interactive_tree, enabled when the session is locked
locked_tree: *wlr.SceneTree,

/// All direct children of the normal_tree scene node
layers: struct {
    /// Background layer shell layer
    background: *wlr.SceneTree,
    /// Bottom layer shell layer
    bottom: *wlr.SceneTree,
    /// Windows and shell surfaces of the window manager
    wm: *wlr.SceneTree,
    /// Top layer shell layer
    top: *wlr.SceneTree,
    /// Overlay layer shell layer
    overlay: *wlr.SceneTree,
    /// Popups from xdg-shell and input-method-v2 clients
    popups: *wlr.SceneTree,
    /// Xwayland override redirect windows are a legacy wart that decide where
    /// to place themselves in layout coordinates. Unfortunately this is how
    /// X11 decided to make dropdown menus and the like possible.
    override_redirect: if (build_options.xwayland) *wlr.SceneTree else void,
},

pub fn init(scene: *Scene) !void {
    const wlr_scene = try wlr.Scene.create();
    errdefer wlr_scene.tree.node.destroy();

    const interactive_tree = try wlr_scene.tree.createSceneTree();
    const drag_icons = try wlr_scene.tree.createSceneTree();
    const hidden_tree = try wlr_scene.tree.createSceneTree();
    hidden_tree.node.setEnabled(false);

    const normal_tree = try interactive_tree.createSceneTree();
    const locked_tree = try interactive_tree.createSceneTree();

    scene.* = .{
        .wlr_scene = wlr_scene,
        .interactive_tree = interactive_tree,
        .drag_icons = drag_icons,
        .hidden_tree = hidden_tree,
        .normal_tree = normal_tree,
        .locked_tree = locked_tree,
        .layers = .{
            .background = try normal_tree.createSceneTree(),
            .bottom = try normal_tree.createSceneTree(),
            .wm = try normal_tree.createSceneTree(),
            .top = try normal_tree.createSceneTree(),
            .overlay = try normal_tree.createSceneTree(),
            .popups = try normal_tree.createSceneTree(),
            .override_redirect = if (build_options.xwayland) try normal_tree.createSceneTree(),
        },
    };
}

pub const AtResult = struct {
    node: *wlr.SceneNode,
    surface: ?*wlr.Surface,
    sx: f64,
    sy: f64,
    data: SceneNodeData.Data,
};

/// Return information about what is currently rendered in the interactive_tree
/// tree at the given layout coordinates, taking surface input regions into account.
pub fn at(scene: *const Scene, lx: f64, ly: f64) ?AtResult {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    const node = scene.interactive_tree.node.at(lx, ly, &sx, &sy) orelse return null;

    const surface: ?*wlr.Surface = blk: {
        if (node.type == .buffer) {
            const scene_buffer = wlr.SceneBuffer.fromNode(node);
            if (wlr.SceneSurface.tryFromBuffer(scene_buffer)) |scene_surface| {
                break :blk scene_surface.surface;
            }
        }
        break :blk null;
    };

    if (SceneNodeData.fromNode(node)) |scene_node_data| {
        return .{
            .node = node,
            .surface = surface,
            .sx = sx,
            .sy = sy,
            .data = scene_node_data.data,
        };
    } else {
        return null;
    }
}
