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

const Box = @import("Box.zig");
const Log = @import("log.zig").Log;
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XdgPopup = @import("XdgPopup.zig");

/// The view this xwayland view implements
view: *View,

/// The corresponding wlroots object
wlr_xwayland_surface: *c.wlr_xwayland_surface,

// Listeners that are always active over the view's lifetime
listen_destroy: c.wl_listener,
listen_map: c.wl_listener,
listen_unmap: c.wl_listener,

// Listeners that are only active while the view is mapped
listen_commit: c.wl_listener,

pub fn init(self: *Self, view: *View, wlr_xwayland_surface: *c.wlr_xwayland_surface) void {
    self.view = view;
    self.wlr_xwayland_surface = wlr_xwayland_surface;
    wlr_xwayland_surface.data = self;

    // Add listeners that are active over the view's entire lifetime
    self.listen_destroy.notify = handleDestroy;
    c.wl_signal_add(&self.wlr_xwayland_surface.events.destroy, &self.listen_destroy);

    self.listen_map.notify = handleMap;
    c.wl_signal_add(&self.wlr_xwayland_surface.events.map, &self.listen_map);

    self.listen_unmap.notify = handleUnmap;
    c.wl_signal_add(&self.wlr_xwayland_surface.events.unmap, &self.listen_unmap);
}

/// Tell the client to take a new size
pub fn configure(self: Self, pending_box: Box) void {
    c.wlr_xwayland_surface_configure(
        self.wlr_xwayland_surface,
        @intCast(i16, pending_box.x),
        @intCast(i16, pending_box.y),
        @intCast(u16, pending_box.width),
        @intCast(u16, pending_box.height),
    );
    // Xwayland surfaces don't use serials, so we will just assume they have
    // configured the next time they commit. Set pending serial to a dummy
    // value to indicate that a transaction has started. Note: we can't just
    // call notifyConfigured() here as the transaction has not yet been fully
    // initiated.
    self.view.pending_serial = 0x66666666;
}

/// Inform the xwayland surface that it has gained focus
pub fn setActivated(self: Self, activated: bool) void {
    c.wlr_xwayland_surface_activate(self.wlr_xwayland_surface, activated);
}

/// Close the view. This will lead to the unmap and destroy events being sent
pub fn close(self: Self) void {
    c.wlr_xwayland_surface_close(self.wlr_xwayland_surface);
}

/// Iterate over all surfaces of the xwayland view.
pub fn forEachSurface(
    self: Self,
    iterator: c.wlr_surface_iterator_func_t,
    user_data: ?*c_void,
) void {
    c.wlr_surface_for_each_surface(self.wlr_xwayland_surface.surface, iterator, user_data);
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

/// Called when the xwayland surface is destroyed
fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_destroy", listener.?);
    const output = self.view.output;

    // Remove listeners that are active for the entire lifetime of the view
    c.wl_list_remove(&self.listen_destroy.link);
    c.wl_list_remove(&self.listen_map.link);
    c.wl_list_remove(&self.listen_unmap.link);

    // Remove the view from the stack
    const node = @fieldParentPtr(ViewStack(View).Node, "view", self.view);
    output.views.remove(node);
    output.root.server.allocator.destroy(node);
}

/// Called when the xwayland surface is mapped, or ready to display on-screen.
fn handleMap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_map", listener.?);
    const view = self.view;
    const root = view.output.root;

    // Add listeners that are only active while mapped
    self.listen_commit.notify = handleCommit;
    c.wl_signal_add(&self.wlr_xwayland_surface.surface.*.events.commit, &self.listen_commit);

    view.wlr_surface = self.wlr_xwayland_surface.surface;
    view.floating = false;

    view.natural_width = self.wlr_xwayland_surface.width;
    view.natural_height = self.wlr_xwayland_surface.height;

    view.map();
}

/// Called when the surface is unmapped and will no longer be displayed.
fn handleUnmap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_unmap", listener.?);

    self.view.unmap();

    // Remove listeners that are only active while mapped
    c.wl_list_remove(&self.listen_commit.link);
}

/// Called when the surface is comitted
/// TODO: check for unexpected change in size and react as needed
fn handleCommit(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_commit", listener.?);
    const view = self.view;
    // See comment in XwaylandView.configure()
    if (view.pending_serial != null) {
        view.output.root.notifyConfigured();
        view.pending_serial = null;
    }
}
