// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
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

const c = @import("c.zig");
const util = @import("util.zig");

const Box = @import("Box.zig");
const Root = @import("Root.zig");

root: *Root,

/// The corresponding wlroots object
wlr_xwayland_surface: *c.wlr_xwayland_surface,

// Listeners that are always active over the view's lifetime
liseten_request_configure: c.wl_listener = undefined,
listen_destroy: c.wl_listener = undefined,
listen_map: c.wl_listener = undefined,
listen_unmap: c.wl_listener = undefined,

// Listeners that are only active while the view is mapped
listen_commit: c.wl_listener = undefined,

pub fn init(self: *Self, root: *Root, wlr_xwayland_surface: *c.wlr_xwayland_surface) void {
    self.* = .{ .root = root, .wlr_xwayland_surface = wlr_xwayland_surface };

    // Add listeners that are active over the view's entire lifetime
    self.liseten_request_configure.notify = handleRequestConfigure;
    c.wl_signal_add(&wlr_xwayland_surface.events.request_configure, &self.liseten_request_configure);

    self.listen_destroy.notify = handleDestroy;
    c.wl_signal_add(&wlr_xwayland_surface.events.destroy, &self.listen_destroy);

    self.listen_map.notify = handleMap;
    c.wl_signal_add(&wlr_xwayland_surface.events.map, &self.listen_map);

    self.listen_unmap.notify = handleUnmap;
    c.wl_signal_add(&wlr_xwayland_surface.events.unmap, &self.listen_unmap);
}

/// Return the surface at output coordinates ox, oy and set sx, sy to the
/// corresponding surface-relative coordinates, if there is a surface.
pub fn surfaceAt(self: Self, ox: f64, oy: f64, sx: *f64, sy: *f64) ?*c.wlr_surface {
    return c.wlr_surface_surface_at(
        self.wlr_xwayland_surface.surface,
        ox - @intToFloat(f64, self.view.current_box.x),
        oy - @intToFloat(f64, self.view.current_box.y),
        sx,
        sy,
    );
}

fn handleRequestConfigure(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "liseten_request_configure", listener.?);
    const wlr_xwayland_surface_configure_event = util.voidCast(c.wlr_xwayland_surface_configure_event, data.?);
    c.wlr_xwayland_surface_configure(
        self.wlr_xwayland_surface,
        wlr_xwayland_surface_configure_event.x,
        wlr_xwayland_surface_configure_event.y,
        wlr_xwayland_surface_configure_event.width,
        wlr_xwayland_surface_configure_event.height,
    );
}

/// Called when the xwayland surface is destroyed
fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_destroy", listener.?);

    // Remove listeners that are active for the entire lifetime of the view
    c.wl_list_remove(&self.listen_destroy.link);
    c.wl_list_remove(&self.listen_map.link);
    c.wl_list_remove(&self.listen_unmap.link);

    // Deallocate the node
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    util.gpa.destroy(node);
}

/// Called when the xwayland surface is mapped, or ready to display on-screen.
fn handleMap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_map", listener.?);
    const root = self.root;

    // Add self to the list of unmanaged views in the root
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    root.xwayland_unmanaged_views.prepend(node);

    // Add listeners that are only active while mapped
    self.listen_commit.notify = handleCommit;
    c.wl_signal_add(&self.wlr_xwayland_surface.surface.*.events.commit, &self.listen_commit);

    // TODO: handle keyboard focus
    // if (wlr_xwayland_or_surface_wants_focus(self.wlr_xwayland_surface)) { ...
}

/// Called when the surface is unmapped and will no longer be displayed.
fn handleUnmap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_unmap", listener.?);

    // Remove self from the list of unmanged views in the root
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    self.root.xwayland_unmanaged_views.remove(node);

    // Remove listeners that are only active while mapped
    c.wl_list_remove(&self.listen_commit.link);

    // TODO: return focus
}

/// Called when the surface is comitted
fn handleCommit(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_commit", listener.?);
    // TODO: check if the surface has moved for damage tracking
}
