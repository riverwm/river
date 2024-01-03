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
const assert = std.debug.assert;
const math = std.math;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const XdgPopup = @import("XdgPopup.zig");
const View = @import("View.zig");
const XdgDecoration = @import("XdgDecoration.zig");

const log = std.log.scoped(.xdg_shell);

/// TODO(zig): get rid of this and use @fieldParentPtr(), https://github.com/ziglang/zig/issues/6611
view: *View,

xdg_toplevel: *wlr.XdgToplevel,

decoration: ?XdgDecoration = null,

/// Initialized on map
geometry: wlr.Box = undefined,

configure_state: union(enum) {
    /// No configure has been sent since the last configure was acked.
    idle,
    /// A configure was sent with the given serial but has not yet been acked.
    inflight: u32,
    /// A configure was acked but the surface has not yet been committed.
    acked,
    /// A configure was acked and the surface was committed.
    committed,
} = .idle,

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
request_move: wl.Listener(*wlr.XdgToplevel.event.Move) =
    wl.Listener(*wlr.XdgToplevel.event.Move).init(handleRequestMove),
request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) =
    wl.Listener(*wlr.XdgToplevel.event.Resize).init(handleRequestResize),
set_title: wl.Listener(void) = wl.Listener(void).init(handleSetTitle),
set_app_id: wl.Listener(void) = wl.Listener(void).init(handleSetAppId),

pub fn create(xdg_toplevel: *wlr.XdgToplevel) error{OutOfMemory}!void {
    const view = try View.create(.{ .xdg_toplevel = .{
        .view = undefined,
        .xdg_toplevel = xdg_toplevel,
    } });
    errdefer view.destroy();

    const self = &view.impl.xdg_toplevel;

    // This listener must be added before the scene xdg surface is created.
    // Otherwise, the scene surface nodes will already be disabled by the unmap
    // listeners in the scene xdg surface and scene subsurface tree helpers
    // before our unmap listener is called.
    // However, we need the surface tree to be unchanged in our unmap listener
    // so that we can save the buffers for frame perfection.
    // TODO(wlroots) This is fragile, it would be good if wlroots gave us a
    // better alternative here.
    xdg_toplevel.base.surface.events.unmap.add(&self.unmap);
    errdefer self.unmap.link.remove();

    _ = try view.surface_tree.createSceneXdgSurface(xdg_toplevel.base);

    self.view = view;

    xdg_toplevel.base.data = @intFromPtr(self);
    xdg_toplevel.base.surface.data = @intFromPtr(&view.tree.node);

    // Add listeners that are active over the toplevel's entire lifetime
    xdg_toplevel.base.events.destroy.add(&self.destroy);
    xdg_toplevel.base.surface.events.map.add(&self.map);
    xdg_toplevel.base.events.new_popup.add(&self.new_popup);

    _ = xdg_toplevel.setWmCapabilities(.{ .fullscreen = true });
}

/// Send a configure event, applying the inflight state of the view.
pub fn configure(self: *Self) bool {
    assert(self.configure_state == .idle);

    const inflight = &self.view.inflight;
    const current = &self.view.current;

    const inflight_float = inflight.float or (inflight.output != null and inflight.output.?.layout == null);
    const current_float = current.float or (current.output != null and current.output.?.layout == null);

    // We avoid a special case for newly mapped views which we have not yet
    // configured by setting the current width/height to the initial width/height
    // of the view in handleMap().
    if (inflight.box.width == current.box.width and
        inflight.box.height == current.box.height and
        (inflight.focus != 0) == (current.focus != 0) and
        inflight.fullscreen == current.fullscreen and
        inflight_float == current_float and
        inflight.ssd == current.ssd and
        inflight.resizing == current.resizing)
    {
        return false;
    }

    _ = self.xdg_toplevel.setActivated(inflight.focus != 0);

    _ = self.xdg_toplevel.setFullscreen(inflight.fullscreen);

    if (inflight_float) {
        _ = self.xdg_toplevel.setTiled(.{ .top = false, .bottom = false, .left = false, .right = false });
    } else {
        _ = self.xdg_toplevel.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
    }

    if (self.decoration) |decoration| {
        _ = decoration.wlr_decoration.setMode(if (inflight.ssd) .server_side else .client_side);
    }

    _ = self.xdg_toplevel.setResizing(inflight.resizing);

    // We need to call this wlroots function even if the inflight dimensions
    // match the current dimensions in order to prevent wlroots internal state
    // from getting out of sync in the case where a client has resized itself.
    const configure_serial = self.xdg_toplevel.setSize(inflight.box.width, inflight.box.height);

    // Only track configures with the transaction system if they affect the dimensions of the view.
    if (inflight.box.width == current.box.width and
        inflight.box.height == current.box.height)
    {
        return false;
    }

    self.configure_state = .{
        .inflight = configure_serial,
    };

    return true;
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

pub fn destroyPopups(self: Self) void {
    var it = self.xdg_toplevel.base.popups.safeIterator(.forward);
    while (it.next()) |wlr_xdg_popup| wlr_xdg_popup.destroy();
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "destroy", listener);

    assert(self.decoration == null);

    // Remove listeners that are active for the entire lifetime of the view
    self.destroy.link.remove();
    self.map.link.remove();
    self.unmap.link.remove();

    // The wlr_surface may outlive the wlr_xdg_surface so we must clean up the user data.
    self.xdg_toplevel.base.surface.data = 0;

    const view = self.view;
    view.impl = .none;
    view.destroy();
}

fn handleMap(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "map", listener);
    const view = self.view;

    // Add listeners that are only active while mapped
    self.xdg_toplevel.base.events.ack_configure.add(&self.ack_configure);
    self.xdg_toplevel.base.surface.events.commit.add(&self.commit);
    self.xdg_toplevel.events.request_fullscreen.add(&self.request_fullscreen);
    self.xdg_toplevel.events.request_move.add(&self.request_move);
    self.xdg_toplevel.events.request_resize.add(&self.request_resize);
    self.xdg_toplevel.events.set_title.add(&self.set_title);
    self.xdg_toplevel.events.set_app_id.add(&self.set_app_id);

    self.xdg_toplevel.base.getGeometry(&self.geometry);

    view.pending.box = .{
        .x = 0,
        .y = 0,
        .width = self.geometry.width,
        .height = self.geometry.height,
    };
    view.inflight.box = view.pending.box;
    view.current.box = view.pending.box;

    const state = &self.xdg_toplevel.current;
    const has_fixed_size = state.min_width != 0 and state.min_height != 0 and
        (state.min_width == state.max_width or state.min_height == state.max_height);

    if (self.xdg_toplevel.parent != null or has_fixed_size) {
        // If the self.xdg_toplevel has a parent or has a fixed size make it float.
        // This will be overwritten in View.map() if the view is matched by a rule.
        view.pending.float = true;
    }

    self.view.pending.fullscreen = self.xdg_toplevel.requested.fullscreen;

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
    self.request_move.link.remove();
    self.request_resize.link.remove();
    self.set_title.link.remove();
    self.set_app_id.link.remove();

    self.view.unmap();
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
    switch (self.configure_state) {
        .inflight => |serial| if (acked_configure.serial == serial) {
            self.configure_state = .acked;
        },
        .acked, .idle, .committed => {},
    }
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const self = @fieldParentPtr(Self, "commit", listener);
    const view = self.view;

    {
        const state = &self.xdg_toplevel.current;
        view.constraints = .{
            .min_width = @max(state.min_width, 1),
            .max_width = if (state.max_width > 0) @intCast(state.max_width) else math.maxInt(u31),
            .min_height = @max(state.min_height, 1),
            .max_height = if (state.max_height > 0) @intCast(state.max_height) else math.maxInt(u31),
        };
    }

    const old_geometry = self.geometry;
    self.xdg_toplevel.base.getGeometry(&self.geometry);

    switch (self.configure_state) {
        .idle, .committed => {
            const size_changed = self.geometry.width != old_geometry.width or
                self.geometry.height != old_geometry.height;
            const no_layout = view.current.output != null and view.current.output.?.layout == null;

            if (size_changed) {
                log.info(
                    "client initiated size change: {}x{} -> {}x{}",
                    .{ old_geometry.width, old_geometry.height, self.geometry.width, self.geometry.height },
                );
                if ((view.current.float or no_layout) and !view.current.fullscreen) {
                    view.current.box.width = self.geometry.width;
                    view.current.box.height = self.geometry.height;
                    view.pending.box.width = self.geometry.width;
                    view.pending.box.height = self.geometry.height;
                    server.root.applyPending();
                } else {
                    log.err("client is buggy and initiated size change while tiled or fullscreen", .{});
                }
            }
        },
        // If the client has not yet acked our configure, we need to send a
        // frame done event so that it commits another buffer. These
        // buffers won't be rendered since we are still rendering our
        // stashed buffer from when the transaction started.
        .inflight => view.sendFrameDone(),
        .acked => {
            self.configure_state = .committed;

            if (view.inflight.resizing) {
                view.resizeUpdatePosition(self.geometry.width, self.geometry.height);
            }

            view.inflight.box.width = self.geometry.width;
            view.inflight.box.height = self.geometry.height;
            view.pending.box.width = self.geometry.width;
            view.pending.box.height = self.geometry.height;

            server.root.notifyConfigured();
        },
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

fn handleRequestMove(
    listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
    event: *wlr.XdgToplevel.event.Move,
) void {
    const self = @fieldParentPtr(Self, "request_move", listener);
    const seat: *Seat = @ptrFromInt(event.seat.seat.data);
    const view = self.view;

    if (view.current.output == null or view.pending.output == null) return;
    if (view.current.tags & view.current.output.?.current.tags == 0) return;
    if (view.pending.fullscreen) return;
    if (!(view.pending.float or view.pending.output.?.layout == null)) return;

    switch (seat.cursor.mode) {
        .passthrough, .down => seat.cursor.startMove(view),
        .move, .resize => {},
    }
}

fn handleRequestResize(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
    const self = @fieldParentPtr(Self, "request_resize", listener);
    const seat: *Seat = @ptrFromInt(event.seat.seat.data);
    const view = self.view;

    if (view.current.output == null or view.pending.output == null) return;
    if (view.current.tags & view.current.output.?.current.tags == 0) return;
    if (view.pending.fullscreen) return;
    if (!(view.pending.float or view.pending.output.?.layout == null)) return;

    switch (seat.cursor.mode) {
        .passthrough, .down => seat.cursor.startResize(view, event.edges),
        .move, .resize => {},
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
