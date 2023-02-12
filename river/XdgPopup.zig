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

const XdgPopup = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");

const log = std.log.scoped(.xdg_popup);

wlr_xdg_popup: *wlr.XdgPopup,
/// This isn't terribly clean, but pointing to the output field of the parent
/// View or LayerSurface struct is ok in practice as all popups are destroyed
/// before their parent View or LayerSurface.
output: *const *Output,
/// The root of the surface tree, i.e. the View or LayerSurface popup_tree.
root: *wlr.SceneTree,

tree: *wlr.SceneTree,

destroy: wl.Listener(void) = wl.Listener(void).init(handleDestroy),
new_popup: wl.Listener(*wlr.XdgPopup) = wl.Listener(*wlr.XdgPopup).init(handleNewPopup),
reposition: wl.Listener(void) = wl.Listener(void).init(handleReposition),

pub fn create(
    wlr_xdg_popup: *wlr.XdgPopup,
    root: *wlr.SceneTree,
    parent: *wlr.SceneTree,
    output: *const *Output,
) error{OutOfMemory}!void {
    const xdg_popup = try util.gpa.create(XdgPopup);
    errdefer util.gpa.destroy(xdg_popup);

    xdg_popup.* = .{
        .wlr_xdg_popup = wlr_xdg_popup,
        .output = output,
        .root = root,
        .tree = try parent.createSceneXdgSurface(wlr_xdg_popup.base),
    };

    wlr_xdg_popup.base.events.destroy.add(&xdg_popup.destroy);
    wlr_xdg_popup.base.events.new_popup.add(&xdg_popup.new_popup);
    wlr_xdg_popup.events.reposition.add(&xdg_popup.reposition);

    handleReposition(&xdg_popup.reposition);
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const xdg_popup = @fieldParentPtr(XdgPopup, "destroy", listener);

    xdg_popup.destroy.link.remove();
    xdg_popup.new_popup.link.remove();
    xdg_popup.reposition.link.remove();

    util.gpa.destroy(xdg_popup);
}

fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const xdg_popup = @fieldParentPtr(XdgPopup, "new_popup", listener);

    XdgPopup.create(
        wlr_xdg_popup,
        xdg_popup.root,
        xdg_popup.tree,
        xdg_popup.output,
    ) catch {
        wlr_xdg_popup.resource.postNoMemory();
        return;
    };
}

fn handleReposition(listener: *wl.Listener(void)) void {
    const xdg_popup = @fieldParentPtr(XdgPopup, "reposition", listener);

    var box: wlr.Box = undefined;
    server.root.output_layout.getBox(xdg_popup.output.*.wlr_output, &box);

    var root_lx: c_int = undefined;
    var root_ly: c_int = undefined;
    _ = xdg_popup.root.node.coords(&root_lx, &root_ly);

    box.x -= root_lx;
    box.y -= root_ly;

    xdg_popup.wlr_xdg_popup.unconstrainFromBox(&box);
}
