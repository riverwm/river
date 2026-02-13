// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

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
destroy: wl.Listener(void) = .init(handleDestroy),
request_configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) = .init(handleRequestConfigure),
set_override_redirect: wl.Listener(void) = .init(handleSetOverrideRedirect),
associate: wl.Listener(void) = .init(handleAssociate),
dissociate: wl.Listener(void) = .init(handleDissociate),
set_title: wl.Listener(void) = .init(handleSetTitle),
set_class: wl.Listener(void) = .init(handleSetClass),
set_parent: wl.Listener(void) = .init(handleSetParent),
set_decorations: wl.Listener(void) = .init(handleSetDecorations),
request_maximize: wl.Listener(void) = .init(handleRequestMaximize),
request_fullscreen: wl.Listener(void) = .init(handleRequestFullscreen),
request_minimize: wl.Listener(*wlr.XwaylandSurface.event.Minimize) = .init(handleRequestMinimize),

// Active while the xsurface is associated with a wlr_surface
map: wl.Listener(void) = .init(handleMap),
unmap: wl.Listener(void) = .init(handleUnmap),

pub fn create(xsurface: *wlr.XwaylandSurface) error{OutOfMemory}!void {
    log.debug("new xwayland window: title='{?s}', class='{?s}'", .{
        xsurface.title,
        xsurface.class,
    });

    const window = try Window.create(.{ .xwayland = .{
        .window = undefined,
        .xsurface = xsurface,
    } });
    errdefer window.destroy();

    const xwindow = &window.impl.xwayland;
    xwindow.window = window;

    xsurface.data = xwindow;

    // Add listeners that are active over the window's entire lifetime
    xsurface.events.destroy.add(&xwindow.destroy);
    xsurface.events.associate.add(&xwindow.associate);
    xsurface.events.dissociate.add(&xwindow.dissociate);
    xsurface.events.request_configure.add(&xwindow.request_configure);
    xsurface.events.set_override_redirect.add(&xwindow.set_override_redirect);
    xsurface.events.set_title.add(&xwindow.set_title);
    xsurface.events.set_class.add(&xwindow.set_class);
    xsurface.events.set_parent.add(&xwindow.set_parent);
    xsurface.events.set_decorations.add(&xwindow.set_decorations);
    xsurface.events.request_maximize.add(&xwindow.request_maximize);
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
    const window = xwindow.window;
    const scheduled = &window.configure_scheduled;
    const sent = &window.configure_sent;

    // Sending a 0 width/height to X11 clients is invalid, so fake it
    if (scheduled.width == 0) {
        scheduled.width = xwindow.xsurface.width;
    }
    if (scheduled.height == 0) {
        scheduled.height = xwindow.xsurface.height;
    }
    const width = scheduled.width orelse xwindow.xsurface.width;
    const height = scheduled.height orelse xwindow.xsurface.height;

    // Unlike native Wayland windows, we need to tell X11 windows about their
    // position. However, river does not necessarily know the new position
    // until after a rendering sequence is completed. Therefore, configure()
    // is called both on manageFinish() and renderFinish() for Xwayland windows.
    // Frame perfection is not achievable for Xwayland windows in any case.
    if (window.rendering_requested.x != xwindow.xsurface.x or
        window.rendering_requested.y != xwindow.xsurface.y or
        width != xwindow.xsurface.width or
        height != xwindow.xsurface.height)
    {
        xwindow.xsurface.configure(
            math.lossyCast(i16, window.rendering_requested.x),
            math.lossyCast(i16, window.rendering_requested.y),
            math.lossyCast(u16, width),
            math.lossyCast(u16, height),
        );
    }

    if (scheduled.activated != sent.activated) {
        xwindow.setActivated(scheduled.activated);
    }
    if (scheduled.maximized != sent.maximized) {
        xwindow.xsurface.setMaximized(scheduled.maximized, scheduled.maximized);
    }
    if (scheduled.inform_fullscreen != sent.inform_fullscreen) {
        xwindow.xsurface.setFullscreen(scheduled.inform_fullscreen);
    }
    window.configure_sent = window.configure_scheduled;
    window.configure_sent.width = width;
    window.configure_sent.height = height;
    window.configure_scheduled.width = null;
    window.configure_scheduled.height = null;

    return false;
}

fn setActivated(xwindow: XwaylandWindow, activated: bool) void {
    // See comment on handleRequestMinimize() for details
    if (activated and xwindow.xsurface.minimized) {
        xwindow.xsurface.setMinimized(false);
    }
    xwindow.xsurface.activate(activated);
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
    xwindow.set_parent.link.remove();
    xwindow.set_decorations.link.remove();
    xwindow.request_maximize.link.remove();
    xwindow.request_fullscreen.link.remove();
    xwindow.request_minimize.link.remove();

    xwindow.xsurface.data = null;

    const window = xwindow.window;
    window.impl = .destroying;
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
    const surface = xwindow.xsurface.surface.?;

    xwindow.surface_tree = window.surfaces.tree.createSceneSubsurfaceTree(surface) catch {
        log.err("out of memory", .{});
        surface.resource.getClient().postNoMemory();
        return;
    };
    surface.data = &window.tree.node;

    // TODO(wlroots) update the dimensions_hint if the size hints change
    // https://gitlab.freedesktop.org/wlroots/wlroots/-/merge_requests/5238
    if (xwindow.xsurface.size_hints) |size_hints| {
        const min_width: u31 = @max(0, size_hints.min_width);
        const min_height: u31 = @max(0, size_hints.min_height);
        window.setDimensionsHint(.{
            .min_width = min_width,
            .max_width = @max(min_width, size_hints.max_width),
            .min_height = min_height,
            .max_height = @max(min_height, size_hints.max_height),
        });
    }

    window.state = .initialized;
    window.map() catch {
        log.err("out of memory", .{});
        surface.resource.getClient().postNoMemory();
    };
    server.wm.dirtyWindowing();
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("unmap", listener);

    xwindow.xsurface.surface.?.data = null;

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

    xwindow.xsurface.configure(
        math.lossyCast(i16, xwindow.window.box.x),
        math.lossyCast(i16, xwindow.window.box.y),
        event.width,
        event.height,
    );
    xwindow.window.setDimensions(event.width, event.height);
}

fn handleSetOverrideRedirect(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("set_override_redirect", listener);
    const xsurface = xwindow.xsurface;

    log.debug("xwayland surface set override redirect", .{});

    assert(xsurface.override_redirect);

    if (xsurface.surface) |surface| {
        if (surface.mapped) {
            handleUnmap(&xwindow.unmap);
        }
        handleDissociate(&xwindow.dissociate);
    }
    handleDestroy(&xwindow.destroy);

    XwaylandOverrideRedirect.create(xsurface) catch {
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

fn handleSetParent(_: *wl.Listener(void)) void {
    server.wm.dirtyWindowing();
}

fn handleSetDecorations(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("set_decorations", listener);

    if (xwindow.xsurface.decorations.no_border or xwindow.xsurface.decorations.no_title) {
        xwindow.window.setDecorationHint(.prefers_csd);
    } else {
        xwindow.window.setDecorationHint(.prefers_ssd);
    }
}

fn handleRequestMaximize(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("request_maximize", listener);
    if (xwindow.xsurface.maximized_vert or xwindow.xsurface.maximized_horz) {
        xwindow.window.wm_scheduled.maximize_requested = .maximize;
    } else {
        xwindow.window.wm_scheduled.maximize_requested = .unmaximize;
    }
    server.wm.dirtyWindowing();
}

fn handleRequestFullscreen(listener: *wl.Listener(void)) void {
    const xwindow: *XwaylandWindow = @fieldParentPtr("request_fullscreen", listener);
    if (xwindow.xsurface.fullscreen) {
        xwindow.window.wm_scheduled.fullscreen_requested = .{ .fullscreen = null };
    } else {
        xwindow.window.wm_scheduled.fullscreen_requested = .exit;
    }
    server.wm.dirtyWindowing();
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
    xwindow.window.wm_scheduled.minimize_requested = true;
    server.wm.dirtyWindowing();
}
