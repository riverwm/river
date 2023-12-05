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
const View = @import("View.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");

const log = std.log.scoped(.xwayland);

/// TODO(zig): get rid of this and use @fieldParentPtr(), https://github.com/ziglang/zig/issues/6611
view: *View,

xwayland_surface: *wlr.XwaylandSurface,
/// Created on map and destroyed on unmap
surface_tree: ?*wlr.SceneTree = null,

// Active over entire lifetime
destroy: wl.Listener(void) = wl.Listener(void).init(handleDestroy),
request_configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) =
    wl.Listener(*wlr.XwaylandSurface.event.Configure).init(handleRequestConfigure),
set_override_redirect: wl.Listener(void) = wl.Listener(void).init(handleSetOverrideRedirect),
associate: wl.Listener(void) = wl.Listener(void).init(handleAssociate),
dissociate: wl.Listener(void) = wl.Listener(void).init(handleDissociate),

// Active while the xwayland_surface is associated with a wlr_surface
map: wl.Listener(void) = wl.Listener(void).init(handleMap),
unmap: wl.Listener(void) = wl.Listener(void).init(handleUnmap),

// Active while mapped
set_title: wl.Listener(void) = wl.Listener(void).init(handleSetTitle),
set_class: wl.Listener(void) = wl.Listener(void).init(handleSetClass),
set_decorations: wl.Listener(void) = wl.Listener(void).init(handleSetDecorations),
request_fullscreen: wl.Listener(void) = wl.Listener(void).init(handleRequestFullscreen),
request_minimize: wl.Listener(*wlr.XwaylandSurface.event.Minimize) =
    wl.Listener(*wlr.XwaylandSurface.event.Minimize).init(handleRequestMinimize),

pub fn create(xwayland_surface: *wlr.XwaylandSurface) error{OutOfMemory}!void {
    const view = try View.create(.{ .xwayland_view = .{
        .view = undefined,
        .xwayland_surface = xwayland_surface,
    } });
    errdefer view.destroy();

    const self = &view.impl.xwayland_view;
    self.view = view;

    // Add listeners that are active over the view's entire lifetime
    xwayland_surface.events.destroy.add(&self.destroy);
    xwayland_surface.events.associate.add(&self.associate);
    xwayland_surface.events.dissociate.add(&self.dissociate);
    xwayland_surface.events.request_configure.add(&self.request_configure);
    xwayland_surface.events.set_override_redirect.add(&self.set_override_redirect);

    if (xwayland_surface.surface) |surface| {
        handleAssociate(&self.associate);
        if (surface.mapped) {
            handleMap(&self.map);
        }
    }
}

/// Always returns false as we do not care about frame perfection for Xwayland views.
pub fn configure(self: Self) bool {
    const output = self.view.inflight.output orelse return false;

    var output_box: wlr.Box = undefined;
    server.root.output_layout.getBox(output.wlr_output, &output_box);

    const inflight = &self.view.inflight;
    const current = &self.view.current;

    if (self.xwayland_surface.x == inflight.box.x + output_box.x and
        self.xwayland_surface.y == inflight.box.y + output_box.y and
        self.xwayland_surface.width == inflight.box.width and
        self.xwayland_surface.height == inflight.box.height and
        (inflight.focus != 0) == (current.focus != 0) and
        (output.inflight.fullscreen == self.view) ==
        (current.output != null and current.output.?.current.fullscreen == self.view))
    {
        return false;
    }

    self.xwayland_surface.configure(
        @intCast(inflight.box.x + output_box.x),
        @intCast(inflight.box.y + output_box.y),
        @intCast(inflight.box.width),
        @intCast(inflight.box.height),
    );

    self.setActivated(inflight.focus != 0);

    self.xwayland_surface.setFullscreen(output.inflight.fullscreen == self.view);

    return false;
}

pub fn rootSurface(self: Self) *wlr.Surface {
    return self.xwayland_surface.surface.?;
}

/// Close the view. This will lead to the unmap and destroy events being sent
pub fn close(self: Self) void {
    self.xwayland_surface.close();
}

fn setActivated(self: Self, activated: bool) void {
    // See comment on handleRequestMinimize() for details
    if (activated and self.xwayland_surface.minimized) {
        self.xwayland_surface.setMinimized(false);
    }
    self.xwayland_surface.activate(activated);
    if (activated) {
        self.xwayland_surface.restack(null, .above);
    }
}

/// Get the current title of the xwayland surface if any.
pub fn getTitle(self: Self) ?[*:0]const u8 {
    return self.xwayland_surface.title;
}
/// X11 clients don't have an app_id but the class serves a similar role.
/// Get the current class of the xwayland surface if any.
pub fn getAppId(self: Self) ?[*:0]const u8 {
    return self.xwayland_surface.class;
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "destroy", listener);

    // Remove listeners that are active for the entire lifetime of the view
    self.destroy.link.remove();
    self.associate.link.remove();
    self.dissociate.link.remove();
    self.request_configure.link.remove();
    self.set_override_redirect.link.remove();

    const view = self.view;
    view.impl = .none;
    view.destroy();
}

fn handleAssociate(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "associate", listener);

    self.xwayland_surface.surface.?.events.map.add(&self.map);
    self.xwayland_surface.surface.?.events.unmap.add(&self.unmap);
}

fn handleDissociate(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "dissociate", listener);
    self.map.link.remove();
    self.unmap.link.remove();
}

pub fn handleMap(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "map", listener);
    const view = self.view;

    const xwayland_surface = self.xwayland_surface;
    const surface = xwayland_surface.surface.?;
    surface.data = @intFromPtr(&view.tree.node);

    // Add listeners that are only active while mapped
    xwayland_surface.events.set_title.add(&self.set_title);
    xwayland_surface.events.set_class.add(&self.set_class);
    xwayland_surface.events.set_decorations.add(&self.set_decorations);
    xwayland_surface.events.request_fullscreen.add(&self.request_fullscreen);
    xwayland_surface.events.request_minimize.add(&self.request_minimize);

    self.surface_tree = view.surface_tree.createSceneSubsurfaceTree(surface) catch {
        log.err("out of memory", .{});
        surface.resource.getClient().postNoMemory();
        return;
    };

    view.pending.box = .{
        .x = 0,
        .y = 0,
        .width = self.xwayland_surface.width,
        .height = self.xwayland_surface.height,
    };
    view.inflight.box = view.pending.box;
    view.current.box = view.pending.box;

    // A value of -1 seems to indicate being unset for these size hints.
    const has_fixed_size = if (self.xwayland_surface.size_hints) |size_hints|
        size_hints.min_width > 0 and size_hints.min_height > 0 and
            (size_hints.min_width == size_hints.max_width or size_hints.min_height == size_hints.max_height)
    else
        false;

    if (self.xwayland_surface.parent != null or has_fixed_size) {
        // If the toplevel has a parent or has a fixed size make it float by default.
        // This will be overwritten in View.map() if the view is matched by a rule.
        view.pending.float = true;
    }

    // This will be overwritten in View.map() if the view is matched by a rule.
    view.pending.ssd = !xwayland_surface.decorations.no_border;

    view.pending.fullscreen = xwayland_surface.fullscreen;

    view.map() catch {
        log.err("out of memory", .{});
        surface.resource.getClient().postNoMemory();
    };
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "unmap", listener);

    self.xwayland_surface.surface.?.data = 0;

    // Remove listeners that are only active while mapped
    self.set_title.link.remove();
    self.set_class.link.remove();
    self.request_fullscreen.link.remove();
    self.request_minimize.link.remove();

    self.view.unmap();

    // Don't destroy the surface tree until after View.unmap() has a chance
    // to save buffers for frame perfection.
    self.surface_tree.?.node.destroy();
    self.surface_tree = null;
}

fn handleRequestConfigure(
    listener: *wl.Listener(*wlr.XwaylandSurface.event.Configure),
    event: *wlr.XwaylandSurface.event.Configure,
) void {
    const self = @fieldParentPtr(Self, "request_configure", listener);

    // If unmapped, let the client do whatever it wants
    if (self.xwayland_surface.surface == null or
        !self.xwayland_surface.surface.?.mapped)
    {
        self.xwayland_surface.configure(event.x, event.y, event.width, event.height);
        return;
    }

    // Allow xwayland views to set their own dimensions (but not position) if floating
    if (self.view.pending.float) {
        self.view.pending.box.width = event.width;
        self.view.pending.box.height = event.height;
    }
    server.root.applyPending();
}

fn handleSetOverrideRedirect(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "set_override_redirect", listener);
    const xwayland_surface = self.xwayland_surface;

    log.debug("xwayland surface set override redirect", .{});

    assert(xwayland_surface.override_redirect);

    if (xwayland_surface.surface) |surface| {
        if (surface.mapped) {
            handleUnmap(&self.unmap);
        }
        handleDissociate(&self.dissociate);
    }
    handleDestroy(&self.destroy);

    XwaylandOverrideRedirect.create(xwayland_surface) catch {
        log.err("out of memory", .{});
        return;
    };
}

fn handleSetTitle(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "set_title", listener);
    self.view.notifyTitle();
}

fn handleSetClass(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "set_class", listener);
    self.view.notifyAppId();
}

fn handleSetDecorations(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "set_decorations", listener);
    const view = self.view;

    const ssd = server.config.rules.ssd.match(view) orelse
        !self.xwayland_surface.decorations.no_border;

    if (view.pending.ssd != ssd) {
        view.pending.ssd = ssd;
        server.root.applyPending();
    }
}

fn handleRequestFullscreen(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "request_fullscreen", listener);
    if (self.view.pending.fullscreen != self.xwayland_surface.fullscreen) {
        self.view.pending.fullscreen = self.xwayland_surface.fullscreen;
        server.root.applyPending();
    }
}

/// Some X11 clients will minimize themselves regardless of how we respond.
/// Therefore to ensure they don't get stuck in this minimized state we tell
/// them their request has been honored without actually doing anything and
/// unminimize them if they gain focus while minimized.
fn handleRequestMinimize(
    listener: *wl.Listener(*wlr.XwaylandSurface.event.Minimize),
    event: *wlr.XwaylandSurface.event.Minimize,
) void {
    const self = @fieldParentPtr(Self, "request_minimize", listener);
    self.xwayland_surface.setMinimized(event.minimize);
}
