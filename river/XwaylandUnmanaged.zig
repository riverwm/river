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
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Box = @import("Box.zig");

/// The corresponding wlroots object
xwayland_surface: *wlr.XwaylandSurface,

// Listeners that are always active over the view's lifetime
request_configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) =
    wl.Listener(*wlr.XwaylandSurface.event.Configure).init(handleRequestConfigure),
destroy: wl.Listener(*wlr.XwaylandSurface) = wl.Listener(*wlr.XwaylandSurface).init(handleDestroy),
map: wl.Listener(*wlr.XwaylandSurface) = wl.Listener(*wlr.XwaylandSurface).init(handleMap),
unmap: wl.Listener(*wlr.XwaylandSurface) = wl.Listener(*wlr.XwaylandSurface).init(handleUnmap),
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),

pub fn init(self: *Self, xwayland_surface: *wlr.XwaylandSurface) void {
    self.* = .{ .xwayland_surface = xwayland_surface };

    // Add listeners that are active over the the entire lifetime
    xwayland_surface.events.request_configure.add(&self.request_configure);
    xwayland_surface.events.destroy.add(&self.destroy);
    xwayland_surface.events.map.add(&self.map);
    xwayland_surface.events.unmap.add(&self.unmap);
}

fn handleRequestConfigure(
    _: *wl.Listener(*wlr.XwaylandSurface.event.Configure),
    event: *wlr.XwaylandSurface.event.Configure,
) void {
    event.surface.configure(event.x, event.y, event.width, event.height);
}

/// Called when the xwayland surface is destroyed
fn handleDestroy(listener: *wl.Listener(*wlr.XwaylandSurface), _: *wlr.XwaylandSurface) void {
    const self = @fieldParentPtr(Self, "destroy", listener);

    // Remove listeners that are active for the entire lifetime
    self.request_configure.link.remove();
    self.destroy.link.remove();
    self.map.link.remove();
    self.unmap.link.remove();

    // Deallocate the node
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    util.gpa.destroy(node);
}

/// Called when the xwayland surface is mapped, or ready to display on-screen.
fn handleMap(listener: *wl.Listener(*wlr.XwaylandSurface), xwayland_surface: *wlr.XwaylandSurface) void {
    const self = @fieldParentPtr(Self, "map", listener);

    // Add self to the list of unmanaged views in the root
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    server.root.xwayland_unmanaged_views.prepend(node);

    xwayland_surface.surface.?.events.commit.add(&self.commit);

    // TODO: handle keyboard focus
    // if (wlr_xwayland_or_surface_wants_focus(self.xwayland_surface)) { ...
}

/// Called when the surface is unmapped and will no longer be displayed.
fn handleUnmap(listener: *wl.Listener(*wlr.XwaylandSurface), _: *wlr.XwaylandSurface) void {
    const self = @fieldParentPtr(Self, "unmap", listener);

    // Remove self from the list of unmanged views in the root
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    server.root.xwayland_unmanaged_views.remove(node);

    self.commit.link.remove();
}

fn handleCommit(_: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    var it = server.root.outputs.first;
    while (it) |node| : (it = node.next) node.data.damage.?.addWhole();
}
