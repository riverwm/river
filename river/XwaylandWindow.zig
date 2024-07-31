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

xsurface: *wlr.XwaylandSurface,
/// Created on map and destroyed on unmap
surface_tree: ?*wlr.SceneTree = null,

// Active over entire lifetime
destroy: wl.Listener(void) = wl.Listener(void).init(handleDestroy),
request_configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) =
    wl.Listener(*wlr.XwaylandSurface.event.Configure).init(handleRequestConfigure),
set_override_redirect: wl.Listener(void) = wl.Listener(void).init(handleSetOverrideRedirect),
associate: wl.Listener(void) = wl.Listener(void).init(handleAssociate),
dissociate: wl.Listener(void) = wl.Listener(void).init(handleDissociate),
set_title: wl.Listener(void) = wl.Listener(void).init(handleSetTitle),
set_class: wl.Listener(void) = wl.Listener(void).init(handleSetClass),
set_decorations: wl.Listener(void) = wl.Listener(void).init(handleSetDecorations),
request_fullscreen: wl.Listener(void) = wl.Listener(void).init(handleRequestFullscreen),
request_minimize: wl.Listener(*wlr.XwaylandSurface.event.Minimize) =
    wl.Listener(*wlr.XwaylandSurface.event.Minimize).init(handleRequestMinimize),

// Active while the xsurfaceis associated with a wlr_surface
map: wl.Listener(void) = wl.Listener(void).init(handleMap),
unmap: wl.Listener(void) = wl.Listener(void).init(handleUnmap),

pub fn create(xsurface: *wlr.XwaylandSurface) error{OutOfMemory}!void {
    const window = try Window.create(.{ .xwayland = .{
        .window = undefined,
        .xsurface = xsurface,
    } });
    errdefer window.destroy(.assert);

    const xwindow = &window.impl.xwayland;
    xwindow.window = window;

    // Add listeners that are active over the window's entire lifetime
    xsurface.events.destroy.add(&xwindow.destroy);
    xsurface.events.associate.add(&xwindow.associate);
    xsurface.events.dissociate.add(&xwindow.dissociate);
    xsurface.events.request_configure.add(&xwindow.request_configure);
    xsurface.events.set_override_redirect.add(&xwindow.set_override_redirect);
    xsurface.events.set_title.add(&xwindow.set_title);
    xsurface.events.set_class.add(&xwindow.set_class);
    xsurface.events.set_decorations.add(&xwindow.set_decorations);
    xsurface.events.request_fullscreen.add(&xwindow.request_fullscreen);
    xsurface.events.request_minimize.add(&xwindow.request_minimize);

    if (xsurface.surface) |surface| {
        handleAssociate(&xwindow.associate);
        if (surface.mapped) {
            handleMap(&xwindow.map);
        }
    }
}

/// Always returns false as we do not care about frame perfection for Xwayland windows.
pub fn configure(xwindow: *XwaylandWindow) bool {
    const inflight = &xwindow.window.inflight;
    const current = &xwindow.window.current;

    // Sending a 0 width/height to X11 clients is invalid, so fake it
    if (inflight.box.width == 0) {
        inflight.box.width = xwindow.window.pending.box.width;
    }
    if (inflight.box.height == 0) {
        inflight.box.height = xwindow.window.pending.box.height;
    }

    if (inflight.hidden != current.hidden) {
        xwindow.xsurface.setWithdrawn(inflight.hidden);
    }

    if (inflight.box.x != current.box.x or
        inflight.box.y != current.box.y or
        inflight.box.width != current.box.width or
        inflight.box.height != current.box.height)
    {
        xwindow.xsurface.configure(
            math.lossyCast(i16, inflight.box.x),
            math.lossyCast(i16, inflight.box.y),
            math.lossyCast(u16, inflight.box.width),
            math.lossyCast(u16, inflight.box.height),
        );
    }

    if ((inflight.focus != 0) != (current.focus != 0)) {
        xwindow.setActivated(inflight.focus != 0);
    }
    if (inflight.maximized != current.maximized) {
        xwindow.xsurface.setFullscreen(inflight.maximized);
    }
    if (inflight.fullscreen != current.fullscreen) {
        xwindow.xsurface.setFullscreen(inflight.fullscreen);
    }

    return false;
}

fn setActivated(xwindow: XwaylandWindow, activated: bool) void {
    // See comment on handleRequestMinimize() for details
    if (activated and xwindow.xsurface.minimized) {
        xwindow.xsurface.setMinimized(false);
    }
    xwindow.xsurface.activate(activated);
    if (activated) {
        xwindow.xsurface.restack(null, .above);
    }
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("destroy", listener);

    // Remove listeners that are active for the entire lifetime of the window
    xwindow.destroy.link.remove();
    xwindow.associate.link.remove();
    xwindow.dissociate.link.remove();
    xwindow.request_configure.link.remove();
    xwindow.set_override_redirect.link.remove();
    xwindow.set_title.link.remove();
    xwindow.set_class.link.remove();
    xwindow.set_decorations.link.remove();
    xwindow.request_fullscreen.link.remove();
    xwindow.request_minimize.link.remove();

    const window = xwindow.window;
    window.impl = .none;
    window.destroy(.lazy);
}

fn handleAssociate(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("associate", listener);

    xwindow.xsurface.surface.?.events.map.add(&xwindow.map);
    xwindow.xsurface.surface.?.events.unmap.add(&xwindow.unmap);
}

fn handleDissociate(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("dissociate", listener);
    xwindow.map.link.remove();
    xwindow.unmap.link.remove();
}

pub fn handleMap(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("map", listener);
    const window = xwindow.window;

    const xsurface = xwindow.xsurface;
    const surface = xsurface.surface.?;
    surface.data = @intFromPtr(&window.tree.node);

    xwindow.surface_tree = window.surface_tree.createSceneSubsurfaceTree(surface) catch {
        log.err("out of memory", .{});
        surface.resource.getClient().postNoMemory();
        return;
    };

    // XXX this seems like it should be deleted/moved to handleCommit()
    window.pending.box = .{
        .x = 0,
        .y = 0,
        .width = xwindow.xsurface.width,
        .height = xwindow.xsurface.height,
    };
    window.inflight.box = window.pending.box;
    window.current.box = window.pending.box;

    window.map() catch {
        log.err("out of memory", .{});
        surface.resource.getClient().postNoMemory();
    };
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("unmap", listener);

    xwindow.xsurface.surface.?.data = 0;

    xwindow.window.unmap();

    // Don't destroy the surface tree until after Window.unmap() has a chance
    // to save buffers for frame perfection.
    xwindow.surface_tree.?.node.destroy();
    xwindow.surface_tree = null;
}

fn handleRequestConfigure(
    listener: *wl.Listener(*wlr.XwaylandSurface.event.Configure),
    event: *wlr.XwaylandSurface.event.Configure,
) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("request_configure", listener);

    // If unmapped, let the client do whatever it wants
    if (xwindow.xsurface.surface == null or !xwindow.xsurface.surface.?.mapped) {
        xwindow.xsurface.configure(event.x, event.y, event.width, event.height);
        return;
    }

    xwindow.window.pending.box.width = event.width;
    xwindow.window.pending.box.height = event.height;
    server.wm.dirtyPending();
}

fn handleSetOverrideRedirect(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("set_override_redirect", listener);

    log.debug("xwayland surface set override redirect", .{});

    assert(xwindow.xsurface.override_redirect);

    if (xwindow.xsurface.surface) |surface| {
        if (surface.mapped) {
            handleUnmap(&xwindow.unmap);
        }
        handleDissociate(&xwindow.dissociate);
    }
    handleDestroy(&xwindow.destroy);

    XwaylandOverrideRedirect.create(xwindow.xsurface) catch {
        log.err("out of memory", .{});
        return;
    };
}

fn handleSetTitle(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("set_title", listener);
    xwindow.window.notifyTitle();
}

fn handleSetClass(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("set_class", listener);
    xwindow.window.notifyAppId();
}

fn handleSetDecorations(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("set_decorations", listener);

    if (xwindow.xsurface.decorations.no_border or xwindow.xsurface.decorations.no_title) {
        xwindow.window.setDecorationHint(.prefers_csd);
    } else {
        xwindow.window.setDecorationHint(.prefers_ssd);
    }
}

fn handleRequestFullscreen(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("request_fullscreen", listener);
    xwindow.window.setFullscreenRequested(xwindow.xsurface.fullscreen);
}

/// Some X11 clients will minimize themselves regardless of how we respond.
/// Therefore to ensure they don't get stuck in this minimized state we tell
/// them their request has been honored without actually doing anything and
/// unminimize them if they gain focus while minimized.
fn handleRequestMinimize(
    listener: *wl.Listener(*wlr.XwaylandSurface.event.Minimize),
    event: *wlr.XwaylandSurface.event.Minimize,
) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("request_minimize", listener);
    xwindow.xsurface.setMinimized(event.minimize);
}
