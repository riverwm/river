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

/// The view this xdg toplevel implements
view: *View,

/// The corresponding wlroots object
wlr_xdg_surface: *c.wlr_xdg_surface,

// Listeners that are always active over the view's lifetime
listen_destroy: c.wl_listener,
listen_map: c.wl_listener,
listen_unmap: c.wl_listener,

// Listeners that are only active while the view is mapped
listen_commit: c.wl_listener,
listen_new_popup: c.wl_listener,

pub fn init(self: *Self, view: *View, wlr_xdg_surface: *c.wlr_xdg_surface) void {
    self.view = view;
    self.wlr_xdg_surface = wlr_xdg_surface;
    wlr_xdg_surface.data = self;

    // Inform the xdg toplevel that it is tiled.
    // For example this prevents firefox from drawing shadows around itself
    _ = c.wlr_xdg_toplevel_set_tiled(self.wlr_xdg_surface, c.WLR_EDGE_LEFT |
        c.WLR_EDGE_RIGHT | c.WLR_EDGE_TOP | c.WLR_EDGE_BOTTOM);

    // Add listeners that are active over the view's entire lifetime
    self.listen_destroy.notify = handleDestroy;
    c.wl_signal_add(&self.wlr_xdg_surface.events.destroy, &self.listen_destroy);

    self.listen_map.notify = handleMap;
    c.wl_signal_add(&self.wlr_xdg_surface.events.map, &self.listen_map);

    self.listen_unmap.notify = handleUnmap;
    c.wl_signal_add(&self.wlr_xdg_surface.events.unmap, &self.listen_unmap);
}

pub fn configure(self: Self, pending_box: Box) void {
    self.view.pending_serial = c.wlr_xdg_toplevel_set_size(
        self.wlr_xdg_surface,
        pending_box.width,
        pending_box.height,
    );
}

pub fn setActivated(self: Self, activated: bool) void {
    _ = c.wlr_xdg_toplevel_set_activated(self.wlr_xdg_surface, activated);
}

/// Close the view. This will lead to the unmap and destroy events being sent
pub fn close(self: Self) void {
    c.wlr_xdg_toplevel_send_close(self.wlr_xdg_surface);
}

pub fn forEachSurface(
    self: Self,
    iterator: c.wlr_surface_iterator_func_t,
    user_data: ?*c_void,
) void {
    c.wlr_xdg_surface_for_each_surface(self.wlr_xdg_surface, iterator, user_data);
}

/// Return the surface at output coordinates ox, oy and set sx, sy to the
/// corresponding surface-relative coordinates, if there is a surface.
pub fn surfaceAt(self: Self, ox: f64, oy: f64, sx: *f64, sy: *f64) ?*c.wlr_surface {
    return c.wlr_xdg_surface_surface_at(
        self.wlr_xdg_surface,
        ox - @intToFloat(f64, self.view.current_box.x),
        oy - @intToFloat(f64, self.view.current_box.y),
        sx,
        sy,
    );
}

/// Called when the xdg surface is destroyed
fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_destroy", listener.?);
    const output = self.view.output;

    // Remove listeners that are active for the entire lifetime of the view
    c.wl_list_remove(&self.listen_destroy.link);
    c.wl_list_remove(&self.listen_map.link);
    c.wl_list_remove(&self.listen_unmap.link);

    self.view.destroy();
}

/// Called when the xdg surface is mapped, or ready to display on-screen.
fn handleMap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_map", listener.?);
    const view = self.view;
    const root = view.output.root;

    // Add listeners that are only active while mapped
    self.listen_commit.notify = handleCommit;
    c.wl_signal_add(&self.wlr_xdg_surface.surface.*.events.commit, &self.listen_commit);

    self.listen_new_popup.notify = handleNewPopup;
    c.wl_signal_add(&self.wlr_xdg_surface.events.new_popup, &self.listen_new_popup);

    view.wlr_surface = self.wlr_xdg_surface.surface;
    view.floating = false;

    view.natural_width = @intCast(u32, self.wlr_xdg_surface.geometry.width);
    view.natural_height = @intCast(u32, self.wlr_xdg_surface.geometry.height);

    if (view.natural_width == 0 and view.natural_height == 0) {
        view.natural_width = @intCast(u32, self.wlr_xdg_surface.surface.*.current.width);
        view.natural_height = @intCast(u32, self.wlr_xdg_surface.surface.*.current.height);
    }

    const wlr_xdg_toplevel: *c.wlr_xdg_toplevel = @field(
        self.wlr_xdg_surface,
        c.wlr_xdg_surface_union,
    ).toplevel;
    const state = &wlr_xdg_toplevel.current;
    const app_id: [*:0]const u8 = if (wlr_xdg_toplevel.app_id) |id| id else "NULL";

    Log.Debug.log("View with app_id '{}' mapped", .{app_id});

    for (root.server.config.float_filter.items) |filter_app_id| {
        // Make views with app_ids listed in the float filter float
        if (std.mem.eql(u8, std.mem.span(app_id), std.mem.span(filter_app_id))) {
            view.setFloating(true);
            break;
        }
    } else if ((wlr_xdg_toplevel.parent != null) or
        (state.min_width != 0 and state.min_height != 0 and
        (state.min_width == state.max_width or state.min_height == state.max_height)))
    {
        // If the toplevel has a parent or is of fixed size make it float
        view.setFloating(true);
    }

    view.map();
}

/// Called when the surface is unmapped and will no longer be displayed.
fn handleUnmap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_unmap", listener.?);
    const root = self.view.output.root;

    self.view.unmap();

    // Remove listeners that are only active while mapped
    c.wl_list_remove(&self.listen_commit.link);
    c.wl_list_remove(&self.listen_new_popup.link);
}

/// Called when the surface is comitted
/// TODO: check for unexpected change in size and react as needed
fn handleCommit(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_commit", listener.?);
    const view = self.view;

    if (view.pending_serial) |s| {
        if (s == self.wlr_xdg_surface.configure_serial) {
            view.output.root.notifyConfigured();
            view.pending_serial = null;
        }
    }
}

/// Called when a new xdg popup is requested by the client
fn handleNewPopup(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_new_popup", listener.?);
    const wlr_xdg_popup = @ptrCast(*c.wlr_xdg_popup, @alignCast(@alignOf(*c.wlr_xdg_popup), data));
    const server = self.view.output.root.server;

    // This will free itself on destroy
    var xdg_popup = server.allocator.create(XdgPopup) catch unreachable;
    xdg_popup.init(self, wlr_xdg_popup);
}
