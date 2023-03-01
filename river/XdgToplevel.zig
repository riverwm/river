// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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

const Self = @This();

const std = @import("std");
const math = std.math;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const XdgPopup = @import("XdgPopup.zig");
const View = @import("View.zig");

const log = std.log.scoped(.xdg_shell);

/// TODO(zig): get rid of this and use @fieldParentPtr(), https://github.com/ziglang/zig/issues/6611
view: *View,

xdg_toplevel: *wlr.XdgToplevel,

geometry: wlr.Box,

/// Set to true when the client acks the configure with serial View.inflight_serial.
acked_inflight_serial: bool = false,

// Listeners that are always active over the view's lifetime
destroy: wl.Listener(void) = wl.Listener(void).init(handleDestroy),
map: wl.Listener(void) = wl.Listener(void).init(handleMap),
unmap: wl.Listener(void) = wl.Listener(void).init(handleUnmap),
new_popup: wl.Listener(*wlr.XdgPopup) = wl.Listener(*wlr.XdgPopup).init(handleNewPopup),

// Listeners that are only active while the view is mapped
ack_configure: wl.Listener(*wlr.XdgSurface.Configure) =
    wl.Listener(*wlr.XdgSurface.Configure).init(handleAckConfigure),
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),
request_fullscreen: wl.Listener(void) = wl.Listener(void).init(handleRequestFullscreen),
set_title: wl.Listener(void) = wl.Listener(void).init(handleSetTitle),
set_app_id: wl.Listener(void) = wl.Listener(void).init(handleSetAppId),

pub fn create(xdg_toplevel: *wlr.XdgToplevel) error{OutOfMemory}!void {
    const view = try View.create(.{ .xdg_toplevel = .{
        .view = undefined,
        .xdg_toplevel = xdg_toplevel,
        .geometry = undefined,
    } });
    errdefer view.destroy();

    view.impl.xdg_toplevel.view = view;
    xdg_toplevel.base.getGeometry(&view.impl.xdg_toplevel.geometry);

    _ = try view.surface_tree.createSceneXdgSurface(xdg_toplevel.base);

    xdg_toplevel.base.data = @ptrToInt(view);

    // Add listeners that are active over the view's entire lifetime
    const self = &view.impl.xdg_toplevel;
    xdg_toplevel.base.events.destroy.add(&self.destroy);
    xdg_toplevel.base.events.map.add(&self.map);
    xdg_toplevel.base.events.unmap.add(&self.unmap);
    xdg_toplevel.base.events.new_popup.add(&self.new_popup);

    _ = xdg_toplevel.setWmCapabilities(.{ .fullscreen = true });
}

/// Returns true if a configure must be sent to ensure that the inflight
/// dimensions are applied.
pub fn needsConfigure(self: Self) bool {
    const view = self.view;

    // We avoid a special case for newly mapped views which we have not yet
    // configured by setting the current width/height to the initial width/height
    // of the view in handleMap().
    return view.inflight.box.width != view.current.box.width or
        view.inflight.box.height != view.current.box.height or
        (view.inflight.focus != 0) != (view.current.focus != 0) or
        (view.inflight.output != null and view.inflight.output.?.inflight.fullscreen == view) !=
        (view.current.output != null and view.current.output.?.current.fullscreen == view) or
        view.inflight.borders != view.current.borders or
        view.inflight.resizing != view.current.resizing;
}

/// Send a configure event, applying the inflight state of the view.
pub fn configure(self: *Self) void {
    const state = &self.view.inflight;

    self.view.inflight_serial = self.xdg_toplevel.setSize(state.box.width, state.box.height);

    _ = self.xdg_toplevel.setActivated(state.focus != 0);

    const fullscreen = state.output != null and state.output.?.inflight.fullscreen == self.view;
    _ = self.xdg_toplevel.setFullscreen(fullscreen);

    if (state.borders) {
        _ = self.xdg_toplevel.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
    } else {
        _ = self.xdg_toplevel.setTiled(.{ .top = false, .bottom = false, .left = false, .right = false });
    }

    _ = self.xdg_toplevel.setResizing(state.resizing);

    self.acked_inflight_serial = false;
}

pub fn rootSurface(self: Self) *wlr.Surface {
    return self.xdg_toplevel.base.surface;
}

/// Close the view. This will lead to the unmap and destroy events being sent
pub fn close(self: Self) void {
    self.xdg_toplevel.sendClose();
}

/// Return the current title of the toplevel if any.
pub fn getTitle(self: Self) ?[*:0]const u8 {
    return self.xdg_toplevel.title;
}

/// Return the current app_id of the toplevel if any .
pub fn getAppId(self: Self) ?[*:0]const u8 {
    return self.xdg_toplevel.app_id;
}

/// Return bounds on the dimensions of the toplevel.
pub fn getConstraints(self: Self) View.Constraints {
    const state = &self.xdg_toplevel.current;
    return .{
        .min_width = @intCast(u31, math.max(state.min_width, 1)),
        .max_width = if (state.max_width > 0) @intCast(u31, state.max_width) else math.maxInt(u31),
        .min_height = @intCast(u31, math.max(state.min_height, 1)),
        .max_height = if (state.max_height > 0) @intCast(u31, state.max_height) else math.maxInt(u31),
    };
}

pub fn destroyPopups(self: Self) void {
    var it = self.xdg_toplevel.base.popups.safeIterator(.forward);
    while (it.next()) |wlr_xdg_popup| wlr_xdg_popup.destroy();
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "destroy", listener);

    // Remove listeners that are active for the entire lifetime of the view
    self.destroy.link.remove();
    self.map.link.remove();
    self.unmap.link.remove();

    self.view.destroy();
}

fn handleMap(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "map", listener);
    const view = self.view;

    // Add listeners that are only active while mapped
    self.xdg_toplevel.base.events.ack_configure.add(&self.ack_configure);
    self.xdg_toplevel.base.surface.events.commit.add(&self.commit);
    self.xdg_toplevel.events.request_fullscreen.add(&self.request_fullscreen);
    self.xdg_toplevel.events.set_title.add(&self.set_title);
    self.xdg_toplevel.events.set_app_id.add(&self.set_app_id);

    var geometry: wlr.Box = undefined;
    self.xdg_toplevel.base.getGeometry(&geometry);

    view.pending.box = .{
        .x = 0,
        .y = 0,
        .width = geometry.width,
        .height = geometry.height,
    };
    view.inflight.box = view.pending.box;
    view.current.box = view.pending.box;

    const state = &self.xdg_toplevel.current;
    const has_fixed_size = state.min_width != 0 and state.min_height != 0 and
        (state.min_width == state.max_width or state.min_height == state.max_height);

    if (self.xdg_toplevel.parent != null or has_fixed_size) {
        // If the self.xdg_toplevel has a parent or has a fixed size make it float
        view.pending.float = true;
    } else if (server.config.shouldFloat(view)) {
        view.pending.float = true;
    }

    self.view.pending.fullscreen = self.xdg_toplevel.requested.fullscreen;

    view.pending.borders = !server.config.csdAllowed(view);

    view.map() catch {
        log.err("out of memory", .{});
        self.xdg_toplevel.resource.getClient().postNoMemory();
    };
}

/// Called when the surface is unmapped and will no longer be displayed.
fn handleUnmap(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "unmap", listener);

    // Remove listeners that are only active while mapped
    self.ack_configure.link.remove();
    self.commit.link.remove();
    self.request_fullscreen.link.remove();
    self.set_title.link.remove();
    self.set_app_id.link.remove();

    // TODO(wlroots): This enable/disable dance is a workaround for an signal
    // ordering issue with the scene xdg surface helper's unmap handler that
    // disables the node. We however need the node enabled for View.unmap()
    // so that we can save buffers for frame perfection.
    var it = self.view.surface_tree.children.iterator(.forward);
    const xdg_surface_tree_node = it.next().?;
    xdg_surface_tree_node.setEnabled(true);

    self.view.unmap();

    xdg_surface_tree_node.setEnabled(false);
}

fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const self = @fieldParentPtr(Self, "new_popup", listener);

    XdgPopup.create(wlr_xdg_popup, self.view.popup_tree, self.view.popup_tree) catch {
        wlr_xdg_popup.resource.postNoMemory();
        return;
    };
}

fn handleAckConfigure(
    listener: *wl.Listener(*wlr.XdgSurface.Configure),
    acked_configure: *wlr.XdgSurface.Configure,
) void {
    const self = @fieldParentPtr(Self, "ack_configure", listener);
    if (self.view.inflight_serial) |serial| {
        if (serial == acked_configure.serial) {
            self.acked_inflight_serial = true;
        }
    }
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const self = @fieldParentPtr(Self, "commit", listener);
    const view = self.view;

    var new_geometry: wlr.Box = undefined;
    self.xdg_toplevel.base.getGeometry(&new_geometry);

    const size_changed = !std.meta.eql(self.geometry, new_geometry);
    self.geometry = new_geometry;

    if (view.inflight_serial != null) {
        if (self.acked_inflight_serial) {
            view.inflight_serial = null;
            server.root.notifyConfigured();
        } else {
            // If the client has not yet acked our configure, we need to send a
            // frame done event so that it commits another buffer. These
            // buffers won't be rendered since we are still rendering our
            // stashed buffer from when the transaction started.
            view.sendFrameDone();
        }
    } else if (size_changed and !view.current.fullscreen and
        (view.current.float or view.current.output == null or view.current.output.?.layout == null))
    {
        // If the client has decided to resize itself and the view is floating,
        // then respect that resize.
        view.current.box.width = new_geometry.width;
        view.current.box.height = new_geometry.height;
        view.pending.box.width = new_geometry.width;
        view.pending.box.height = new_geometry.height;
        server.root.applyPending();
    }
}

/// Called when the client asks to be fullscreened. We always honor the request
/// for now, perhaps it should be denied in some cases in the future.
fn handleRequestFullscreen(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "request_fullscreen", listener);
    if (self.view.pending.fullscreen != self.xdg_toplevel.requested.fullscreen) {
        self.view.pending.fullscreen = self.xdg_toplevel.requested.fullscreen;
        server.root.applyPending();
    }
}

/// Called when the client sets / updates its title
fn handleSetTitle(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "set_title", listener);
    self.view.notifyTitle();
}

/// Called when the client sets / updates its app_id
fn handleSetAppId(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "set_app_id", listener);
    self.view.notifyAppId();
}
