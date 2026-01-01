// SPDX-FileCopyrightText: © 2023 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const XdgPopup = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");

const log = std.log.scoped(.xdg_popup);

wlr_popup: *wlr.XdgPopup,
/// The root of the surface tree, i.e. the Window's popup_tree
root: *wlr.SceneTree,

tree: *wlr.SceneTree,

destroy: wl.Listener(void) = .init(handleDestroy),
commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
new_popup: wl.Listener(*wlr.XdgPopup) = .init(handleNewPopup),
reposition: wl.Listener(void) = .init(handleReposition),

// TODO check if popup is set_reactive and reposition on parent movement.
pub fn create(
    wlr_popup: *wlr.XdgPopup,
    root: *wlr.SceneTree,
    parent: *wlr.SceneTree,
) error{OutOfMemory}!void {
    const xdg_popup = try util.gpa.create(XdgPopup);
    errdefer util.gpa.destroy(xdg_popup);

    xdg_popup.* = .{
        .wlr_popup = wlr_popup,
        .root = root,
        .tree = try parent.createSceneXdgSurface(wlr_popup.base),
    };

    wlr_popup.events.destroy.add(&xdg_popup.destroy);
    wlr_popup.base.surface.events.commit.add(&xdg_popup.commit);
    wlr_popup.base.events.new_popup.add(&xdg_popup.new_popup);
    wlr_popup.events.reposition.add(&xdg_popup.reposition);
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("destroy", listener);

    xdg_popup.destroy.link.remove();
    xdg_popup.commit.link.remove();
    xdg_popup.new_popup.link.remove();
    xdg_popup.reposition.link.remove();

    util.gpa.destroy(xdg_popup);
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("commit", listener);

    if (xdg_popup.wlr_popup.base.initial_commit) {
        handleReposition(&xdg_popup.reposition);
    }
}

fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_popup: *wlr.XdgPopup) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("new_popup", listener);

    XdgPopup.create(
        wlr_popup,
        xdg_popup.root,
        xdg_popup.tree,
    ) catch {
        wlr_popup.resource.postNoMemory();
        return;
    };
}

fn handleReposition(listener: *wl.Listener(void)) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("reposition", listener);

    var root_lx: c_int = undefined;
    var root_ly: c_int = undefined;
    _ = xdg_popup.root.node.coords(&root_lx, &root_ly);

    const wlr_output = server.om.outputAt(
        @floatFromInt(root_lx + xdg_popup.wlr_popup.scheduled.geometry.x),
        @floatFromInt(root_ly + xdg_popup.wlr_popup.scheduled.geometry.y),
    ) orelse return;

    var box: wlr.Box = undefined;
    server.om.output_layout.getBox(wlr_output, &box);

    box.x -= root_lx;
    box.y -= root_ly;

    xdg_popup.wlr_popup.unconstrainFromBox(&box);
}
