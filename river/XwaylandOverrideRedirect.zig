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

const XwaylandOverrideRedirect = @This();

const std = @import("std");
const assert = std.debug.assert;

const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const SceneNodeData = @import("SceneNodeData.zig");
const View = @import("View.zig");
const XwaylandView = @import("XwaylandView.zig");

const log = std.log.scoped(.xwayland);

xwayland_surface: *wlr.XwaylandSurface,
surface_tree: ?*wlr.SceneTree = null,

// Active over entire lifetime
request_configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) =
    wl.Listener(*wlr.XwaylandSurface.event.Configure).init(handleRequestConfigure),
destroy: wl.Listener(void) = wl.Listener(void).init(handleDestroy),
set_override_redirect: wl.Listener(void) = wl.Listener(void).init(handleSetOverrideRedirect),
associate: wl.Listener(void) = wl.Listener(void).init(handleAssociate),
dissociate: wl.Listener(void) = wl.Listener(void).init(handleDissociate),

// Active while the xwayland_surface is associated with a wlr_surface
map: wl.Listener(void) = wl.Listener(void).init(handleMap),
unmap: wl.Listener(void) = wl.Listener(void).init(handleUnmap),

// Active while mapped
set_geometry: wl.Listener(void) = wl.Listener(void).init(handleSetGeometry),

pub fn create(xwayland_surface: *wlr.XwaylandSurface) error{OutOfMemory}!void {
    const override_redirect = try util.gpa.create(XwaylandOverrideRedirect);
    errdefer util.gpa.destroy(override_redirect);

    override_redirect.* = .{ .xwayland_surface = xwayland_surface };

    xwayland_surface.events.request_configure.add(&override_redirect.request_configure);
    xwayland_surface.events.destroy.add(&override_redirect.destroy);
    xwayland_surface.events.set_override_redirect.add(&override_redirect.set_override_redirect);

    xwayland_surface.events.associate.add(&override_redirect.associate);
    xwayland_surface.events.dissociate.add(&override_redirect.dissociate);

    if (xwayland_surface.surface) |surface| {
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

    override_redirect.xwayland_surface.surface.?.events.map.add(&override_redirect.map);
    override_redirect.xwayland_surface.surface.?.events.unmap.add(&override_redirect.unmap);
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
        override_redirect.xwayland_surface.surface.?.resource.getClient().postNoMemory();
    };
}

fn mapImpl(override_redirect: *XwaylandOverrideRedirect) error{OutOfMemory}!void {
    const surface = override_redirect.xwayland_surface.surface.?;
    override_redirect.surface_tree =
        try server.root.layers.override_redirect.createSceneSubsurfaceTree(surface);
    try SceneNodeData.attach(&override_redirect.surface_tree.?.node, .{
        .override_redirect = override_redirect,
    });

    surface.data = @intFromPtr(&override_redirect.surface_tree.?.node);

    override_redirect.surface_tree.?.node.setPosition(
        override_redirect.xwayland_surface.x,
        override_redirect.xwayland_surface.y,
    );

    override_redirect.xwayland_surface.events.set_geometry.add(&override_redirect.set_geometry);

    override_redirect.focusIfDesired();
}

pub fn focusIfDesired(override_redirect: *XwaylandOverrideRedirect) void {
    if (server.lock_manager.state != .unlocked) return;

    if (override_redirect.xwayland_surface.overrideRedirectWantsFocus() and
        override_redirect.xwayland_surface.icccmInputModel() != .none)
    {
        const seat = server.input_manager.defaultSeat();
        // Keep the parent top-level Xwayland view of any override redirect surface
        // activated while that override redirect surface is focused. This ensures
        // override redirect menus do not disappear as a result of deactivating
        // their parent window.
        if (seat.focused == .view and
            seat.focused.view.impl == .xwayland_view and
            seat.focused.view.impl.xwayland_view.xwayland_surface.pid == override_redirect.xwayland_surface.pid)
        {
            seat.keyboardEnterOrLeave(override_redirect.xwayland_surface.surface);
        } else {
            seat.setFocusRaw(.{ .override_redirect = override_redirect });
        }
    }
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("unmap", listener);

    override_redirect.set_geometry.link.remove();

    override_redirect.xwayland_surface.surface.?.data = 0;
    override_redirect.surface_tree.?.node.destroy();
    override_redirect.surface_tree = null;

    // If the unmapped surface is currently focused, pass keyboard focus
    // to the most appropriate surface.
    var seat_it = server.input_manager.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        const seat = &seat_node.data;
        if (seat.focused == .view and seat.focused.view.impl == .xwayland_view and
            seat.focused.view.impl.xwayland_view.xwayland_surface.pid == override_redirect.xwayland_surface.pid and
            seat.wlr_seat.keyboard_state.focused_surface == override_redirect.xwayland_surface.surface)
        {
            seat.keyboardEnterOrLeave(seat.focused.view.rootSurface());
        }
    }

    server.root.applyPending();
}

fn handleSetGeometry(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("set_geometry", listener);

    override_redirect.surface_tree.?.node.setPosition(
        override_redirect.xwayland_surface.x,
        override_redirect.xwayland_surface.y,
    );
}

fn handleSetOverrideRedirect(listener: *wl.Listener(void)) void {
    const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("set_override_redirect", listener);
    const xwayland_surface = override_redirect.xwayland_surface;

    log.debug("xwayland surface unset override redirect", .{});

    assert(!xwayland_surface.override_redirect);

    if (xwayland_surface.surface) |surface| {
        if (surface.mapped) {
            handleUnmap(&override_redirect.unmap);
        }
        handleDissociate(&override_redirect.dissociate);
    }
    handleDestroy(&override_redirect.destroy);

    XwaylandView.create(xwayland_surface) catch {
        log.err("out of memory", .{});
        return;
    };
}
