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
    const self = try util.gpa.create(Self);
    errdefer util.gpa.destroy(self);

    self.* = .{ .xwayland_surface = xwayland_surface };

    xwayland_surface.events.request_configure.add(&self.request_configure);
    xwayland_surface.events.destroy.add(&self.destroy);
    xwayland_surface.events.set_override_redirect.add(&self.set_override_redirect);

    xwayland_surface.events.associate.add(&self.associate);
    xwayland_surface.events.dissociate.add(&self.dissociate);

    if (xwayland_surface.surface) |surface| {
        handleAssociate(&self.associate);
        if (surface.mapped) {
            handleMap(&self.map);
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
    const self = @fieldParentPtr(Self, "destroy", listener);

    self.request_configure.link.remove();
    self.destroy.link.remove();
    self.associate.link.remove();
    self.dissociate.link.remove();
    self.set_override_redirect.link.remove();

    util.gpa.destroy(self);
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

    self.mapImpl() catch {
        log.err("out of memory", .{});
        self.xwayland_surface.surface.?.resource.getClient().postNoMemory();
    };
}

fn mapImpl(self: *Self) error{OutOfMemory}!void {
    const surface = self.xwayland_surface.surface.?;
    self.surface_tree = try server.root.layers.xwayland_override_redirect.createSceneSubsurfaceTree(surface);
    try SceneNodeData.attach(&self.surface_tree.?.node, .{ .xwayland_override_redirect = self });

    surface.data = @intFromPtr(&self.surface_tree.?.node);

    self.surface_tree.?.node.setPosition(self.xwayland_surface.x, self.xwayland_surface.y);

    self.xwayland_surface.events.set_geometry.add(&self.set_geometry);

    self.focusIfDesired();
}

pub fn focusIfDesired(self: *Self) void {
    if (server.lock_manager.state != .unlocked) return;

    if (self.xwayland_surface.overrideRedirectWantsFocus() and
        self.xwayland_surface.icccmInputModel() != .none)
    {
        const seat = server.input_manager.defaultSeat();
        // Keep the parent top-level Xwayland view of any override redirect surface
        // activated while that override redirect surface is focused. This ensures
        // override redirect menus do not disappear as a result of deactivating
        // their parent window.
        if (seat.focused == .view and
            seat.focused.view.impl == .xwayland_view and
            seat.focused.view.impl.xwayland_view.xwayland_surface.pid == self.xwayland_surface.pid)
        {
            seat.keyboardEnterOrLeave(self.xwayland_surface.surface);
        } else {
            seat.setFocusRaw(.{ .xwayland_override_redirect = self });
        }
    }
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "unmap", listener);

    self.set_geometry.link.remove();

    self.xwayland_surface.surface.?.data = 0;
    self.surface_tree.?.node.destroy();
    self.surface_tree = null;

    // If the unmapped surface is currently focused, pass keyboard focus
    // to the most appropriate surface.
    var seat_it = server.input_manager.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        const seat = &seat_node.data;
        if (seat.focused == .view and seat.focused.view.impl == .xwayland_view and
            seat.focused.view.impl.xwayland_view.xwayland_surface.pid == self.xwayland_surface.pid and
            seat.wlr_seat.keyboard_state.focused_surface == self.xwayland_surface.surface)
        {
            seat.keyboardEnterOrLeave(seat.focused.view.rootSurface());
        }
    }

    server.root.applyPending();
}

fn handleSetGeometry(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "set_geometry", listener);

    self.surface_tree.?.node.setPosition(self.xwayland_surface.x, self.xwayland_surface.y);
}

fn handleSetOverrideRedirect(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "set_override_redirect", listener);
    const xwayland_surface = self.xwayland_surface;

    log.debug("xwayland surface unset override redirect", .{});

    assert(!xwayland_surface.override_redirect);

    if (xwayland_surface.surface) |surface| {
        if (surface.mapped) {
            handleUnmap(&self.unmap);
        }
        handleDissociate(&self.dissociate);
    }
    handleDestroy(&self.destroy);

    XwaylandView.create(xwayland_surface) catch {
        log.err("out of memory", .{});
        return;
    };
}
