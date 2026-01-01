// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const XwaylandOverrideRedirect = @This();

const std = @import("std");
const assert = std.debug.assert;

const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const SceneNodeData = @import("SceneNodeData.zig");
const Window = @import("Window.zig");
const XwaylandWindow = @import("XwaylandWindow.zig");

const log = std.log.scoped(.xwayland);

xsurface: *wlr.XwaylandSurface,
surface_tree: ?*wlr.SceneTree = null,

// Active over entire lifetime
request_configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) = .init(handleRequestConfigure),
destroy: wl.Listener(void) = .init(handleDestroy),
set_override_redirect: wl.Listener(void) = .init(handleSetOverrideRedirect),
associate: wl.Listener(void) = .init(handleAssociate),
dissociate: wl.Listener(void) = .init(handleDissociate),

// Active while the xsurface is associated with a wlr_surface
map: wl.Listener(void) = .init(handleMap),
unmap: wl.Listener(void) = .init(handleUnmap),

// Active while mapped
set_geometry: wl.Listener(void) = .init(handleSetGeometry),

pub fn create(xsurface: *wlr.XwaylandSurface) error{OutOfMemory}!void {
    log.debug("new xwayland override redirect: title='{?s}', class='{?s}'", .{
        xsurface.title,
        xsurface.class,
    });

    const override_redirect = try util.gpa.create(XwaylandOverrideRedirect);
    errdefer util.gpa.destroy(override_redirect);

    override_redirect.* = .{ .xsurface = xsurface };

    xsurface.events.request_configure.add(&override_redirect.request_configure);
    xsurface.events.destroy.add(&override_redirect.destroy);
    xsurface.events.set_override_redirect.add(&override_redirect.set_override_redirect);

    xsurface.events.associate.add(&override_redirect.associate);
    xsurface.events.dissociate.add(&override_redirect.dissociate);

    if (xsurface.surface) |surface| {
        handleAssociate(&override_redirect.associate);
        if (surface.mapped) {
            handleMap(&override_redirect.map);
        }
    }
}

fn handleRequestConfigure(
    _: *wl.Listener(*wlr.XwaylandSurface.event.Configure),
    event: *wlr.XwaylandSurface.event.Configure,
) void {
    event.surface.configure(event.x, event.y, event.width, event.height);
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("destroy", listener);

    override_redirect.request_configure.link.remove();
    override_redirect.destroy.link.remove();
    override_redirect.associate.link.remove();
    override_redirect.dissociate.link.remove();
    override_redirect.set_override_redirect.link.remove();

    util.gpa.destroy(override_redirect);
}

fn handleAssociate(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("associate", listener);

    override_redirect.xsurface.surface.?.events.map.add(&override_redirect.map);
    override_redirect.xsurface.surface.?.events.unmap.add(&override_redirect.unmap);
}

fn handleDissociate(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("dissociate", listener);

    override_redirect.map.link.remove();
    override_redirect.unmap.link.remove();
}

pub fn handleMap(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("map", listener);

    override_redirect.mapImpl() catch {
        log.err("out of memory", .{});
        override_redirect.xsurface.surface.?.resource.getClient().postNoMemory();
    };
}

fn mapImpl(override_redirect: *XwaylandOverrideRedirect) error{OutOfMemory}!void {
    const surface = override_redirect.xsurface.surface.?;
    override_redirect.surface_tree =
        try server.scene.layers.override_redirect.createSceneSubsurfaceTree(surface);
    try SceneNodeData.attach(&override_redirect.surface_tree.?.node, .{
        .override_redirect = override_redirect,
    });

    surface.data = &override_redirect.surface_tree.?.node;

    override_redirect.surface_tree.?.node.setPosition(
        override_redirect.xsurface.x,
        override_redirect.xsurface.y,
    );

    override_redirect.xsurface.events.set_geometry.add(&override_redirect.set_geometry);

    override_redirect.focusIfDesired();
}

pub fn focusIfDesired(override_redirect: *XwaylandOverrideRedirect) void {
    if (server.lock_manager.state != .unlocked) return;

    if (override_redirect.xsurface.overrideRedirectWantsFocus() and
        override_redirect.xsurface.icccmInputModel() != .none)
    {
        const seat = server.input_manager.defaultSeat();
        // Keep the parent top-level Xwayland window of any override redirect surface
        // activated while that override redirect surface is focused. This ensures
        // override redirect menus do not disappear as a result of deactivating
        // their parent window.
        if (seat.focused == .window and
            seat.focused.window.impl == .xwayland and
            seat.focused.window.impl.xwayland.xsurface.pid == override_redirect.xsurface.pid)
        {
            seat.keyboardEnterOrLeave(override_redirect.xsurface.surface);
        } else {
            seat.focus(.{ .override_redirect = override_redirect });
        }
    }
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("unmap", listener);

    override_redirect.set_geometry.link.remove();

    override_redirect.xsurface.surface.?.data = null;
    override_redirect.surface_tree.?.node.destroy();
    override_redirect.surface_tree = null;

    // If the unmapped surface is currently focused, pass keyboard focus
    // to the most appropriate surface.
    var seat_it = server.input_manager.seats.iterator(.forward);
    while (seat_it.next()) |seat| {
        if (seat.focused == .window and seat.focused.window.impl == .xwayland and
            seat.focused.window.impl.xwayland.xsurface.pid == override_redirect.xsurface.pid and
            seat.wlr_seat.keyboard_state.focused_surface == override_redirect.xsurface.surface)
        {
            seat.keyboardEnterOrLeave(seat.focused.window.rootSurface());
        }
    }

    server.wm.dirtyWindowing();
}

fn handleSetGeometry(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("set_geometry", listener);

    override_redirect.surface_tree.?.node.setPosition(
        override_redirect.xsurface.x,
        override_redirect.xsurface.y,
    );
}

fn handleSetOverrideRedirect(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("set_override_redirect", listener);
    const xsurface = override_redirect.xsurface;

    log.debug("xwayland surface unset override redirect", .{});

    assert(!xsurface.override_redirect);

    if (xsurface.surface) |surface| {
        if (surface.mapped) {
            handleUnmap(&override_redirect.unmap);
        }
        handleDissociate(&override_redirect.dissociate);
    }
    handleDestroy(&override_redirect.destroy);

    XwaylandWindow.create(xsurface) catch {
        log.err("out of memory", .{});
        return;
    };
}
