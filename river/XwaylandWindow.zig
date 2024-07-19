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

const XwaylandWindow = @This();

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;

const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const Window = @import("Window.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");

const log = std.log.scoped(.xwayland);

/// TODO(zig): get rid of this and use @fieldParentPtr(), https://github.com/ziglang/zig/issues/6611
window: *Window,

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
    const window = try Window.create(.{ .xwayland_window = .{
        .window = undefined,
        .xwayland_surface = xwayland_surface,
    } });
    errdefer window.destroy(.assert);

    const xwayland_window = &window.impl.xwayland_window;
    xwayland_window.window = window;

    // Add listeners that are active over the window's entire lifetime
    xwayland_surface.events.destroy.add(&xwayland_window.destroy);
    xwayland_surface.events.associate.add(&xwayland_window.associate);
    xwayland_surface.events.dissociate.add(&xwayland_window.dissociate);
    xwayland_surface.events.request_configure.add(&xwayland_window.request_configure);
    xwayland_surface.events.set_override_redirect.add(&xwayland_window.set_override_redirect);

    if (xwayland_surface.surface) |surface| {
        handleAssociate(&xwayland_window.associate);
        if (surface.mapped) {
            handleMap(&xwayland_window.map);
        }
    }
}

/// Always returns false as we do not care about frame perfection for Xwayland windows.
pub fn configure(xwayland_window: XwaylandWindow) bool {
    const inflight = &xwayland_window.window.inflight;
    const current = &xwayland_window.window.current;

    if (xwayland_window.xwayland_surface.x == inflight.box.x and
        xwayland_window.xwayland_surface.y == inflight.box.y and
        xwayland_window.xwayland_surface.width == inflight.box.width and
        xwayland_window.xwayland_surface.height == inflight.box.height and
        (inflight.focus != 0) == (current.focus != 0))
        // TODO fullscreen
    {
        return false;
    }

    xwayland_window.xwayland_surface.configure(
        math.lossyCast(i16, inflight.box.x),
        math.lossyCast(i16, inflight.box.y),
        math.lossyCast(u16, inflight.box.width),
        math.lossyCast(u16, inflight.box.height),
    );

    xwayland_window.setActivated(inflight.focus != 0);

    if (false) xwayland_window.xwayland_surface.setFullscreen();

    return false;
}

fn setActivated(xwayland_window: XwaylandWindow, activated: bool) void {
    // See comment on handleRequestMinimize() for details
    if (activated and xwayland_window.xwayland_surface.minimized) {
        xwayland_window.xwayland_surface.setMinimized(false);
    }
    xwayland_window.xwayland_surface.activate(activated);
    if (activated) {
        xwayland_window.xwayland_surface.restack(null, .above);
    }
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const xwayland_window: *XwaylandWindow = @fieldParentPtr("destroy", listener);

    // Remove listeners that are active for the entire lifetime of the window
    xwayland_window.destroy.link.remove();
    xwayland_window.associate.link.remove();
    xwayland_window.dissociate.link.remove();
    xwayland_window.request_configure.link.remove();
    xwayland_window.set_override_redirect.link.remove();

    const window = xwayland_window.window;
    window.impl = .none;
    window.destroy(.lazy);
}

fn handleAssociate(listener: *wl.Listener(void)) void {
    const xwayland_window: *XwaylandWindow = @fieldParentPtr("associate", listener);

    xwayland_window.xwayland_surface.surface.?.events.map.add(&xwayland_window.map);
    xwayland_window.xwayland_surface.surface.?.events.unmap.add(&xwayland_window.unmap);
}

fn handleDissociate(listener: *wl.Listener(void)) void {
    const xwayland_window: *XwaylandWindow = @fieldParentPtr("dissociate", listener);
    xwayland_window.map.link.remove();
    xwayland_window.unmap.link.remove();
}

pub fn handleMap(listener: *wl.Listener(void)) void {
    const xwayland_window: *XwaylandWindow = @fieldParentPtr("map", listener);
    const window = xwayland_window.window;

    const xwayland_surface = xwayland_window.xwayland_surface;
    const surface = xwayland_surface.surface.?;
    surface.data = @intFromPtr(&window.tree.node);

    // Add listeners that are only active while mapped
    xwayland_surface.events.set_title.add(&xwayland_window.set_title);
    xwayland_surface.events.set_class.add(&xwayland_window.set_class);
    xwayland_surface.events.set_decorations.add(&xwayland_window.set_decorations);
    xwayland_surface.events.request_fullscreen.add(&xwayland_window.request_fullscreen);
    xwayland_surface.events.request_minimize.add(&xwayland_window.request_minimize);

    xwayland_window.surface_tree = window.surface_tree.createSceneSubsurfaceTree(surface) catch {
        log.err("out of memory", .{});
        surface.resource.getClient().postNoMemory();
        return;
    };

    window.pending.box = .{
        .x = 0,
        .y = 0,
        .width = xwayland_window.xwayland_surface.width,
        .height = xwayland_window.xwayland_surface.height,
    };
    window.inflight.box = window.pending.box;
    window.current.box = window.pending.box;

    // This will be overwritten in Window.map() if the window is matched by a rule.
    window.pending.ssd = !xwayland_surface.decorations.no_border;

    window.pending.fullscreen = xwayland_surface.fullscreen;

    window.map() catch {
        log.err("out of memory", .{});
        surface.resource.getClient().postNoMemory();
    };
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const xwayland_window: *XwaylandWindow = @fieldParentPtr("unmap", listener);

    xwayland_window.xwayland_surface.surface.?.data = 0;

    // Remove listeners that are only active while mapped
    xwayland_window.set_title.link.remove();
    xwayland_window.set_class.link.remove();
    xwayland_window.request_fullscreen.link.remove();
    xwayland_window.request_minimize.link.remove();

    xwayland_window.window.unmap();

    // Don't destroy the surface tree until after Window.unmap() has a chance
    // to save buffers for frame perfection.
    xwayland_window.surface_tree.?.node.destroy();
    xwayland_window.surface_tree = null;
}

fn handleRequestConfigure(
    listener: *wl.Listener(*wlr.XwaylandSurface.event.Configure),
    event: *wlr.XwaylandSurface.event.Configure,
) void {
    const xwayland_window: *XwaylandWindow = @fieldParentPtr("request_configure", listener);

    // If unmapped, let the client do whatever it wants
    if (xwayland_window.xwayland_surface.surface == null or
        !xwayland_window.xwayland_surface.surface.?.mapped)
    {
        xwayland_window.xwayland_surface.configure(event.x, event.y, event.width, event.height);
        return;
    }

    // Allow xwayland windows to set their own dimensions (but not position) if floating
    xwayland_window.window.pending.box.width = event.width;
    xwayland_window.window.pending.box.height = event.height;
    server.wm.applyPending();
}

fn handleSetOverrideRedirect(listener: *wl.Listener(void)) void {
    const xwayland_window: *XwaylandWindow = @fieldParentPtr("set_override_redirect", listener);
    const xwayland_surface = xwayland_window.xwayland_surface;

    log.debug("xwayland surface set override redirect", .{});

    assert(xwayland_surface.override_redirect);

    if (xwayland_surface.surface) |surface| {
        if (surface.mapped) {
            handleUnmap(&xwayland_window.unmap);
        }
        handleDissociate(&xwayland_window.dissociate);
    }
    handleDestroy(&xwayland_window.destroy);

    XwaylandOverrideRedirect.create(xwayland_surface) catch {
        log.err("out of memory", .{});
        return;
    };
}

fn handleSetTitle(listener: *wl.Listener(void)) void {
    const xwayland_window: *XwaylandWindow = @fieldParentPtr("set_title", listener);
    xwayland_window.window.notifyTitle();
}

fn handleSetClass(listener: *wl.Listener(void)) void {
    const xwayland_window: *XwaylandWindow = @fieldParentPtr("set_class", listener);
    xwayland_window.window.notifyAppId();
}

fn handleSetDecorations(listener: *wl.Listener(void)) void {
    const xwayland_window: *XwaylandWindow = @fieldParentPtr("set_decorations", listener);
    const window = xwayland_window.window;

    const ssd = !xwayland_window.xwayland_surface.decorations.no_border;

    if (window.pending.ssd != ssd) {
        window.pending.ssd = ssd;
        server.wm.applyPending();
    }
}

fn handleRequestFullscreen(listener: *wl.Listener(void)) void {
    const xwayland_window: *XwaylandWindow = @fieldParentPtr("request_fullscreen", listener);
    if (xwayland_window.window.pending.fullscreen != xwayland_window.xwayland_surface.fullscreen) {
        xwayland_window.window.pending.fullscreen = xwayland_window.xwayland_surface.fullscreen;
        server.wm.applyPending();
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
    const xwayland_window: *XwaylandWindow = @fieldParentPtr("request_minimize", listener);
    xwayland_window.xwayland_surface.setMinimized(event.minimize);
}
