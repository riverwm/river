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
const log = @import("log.zig");
const util = @import("util.zig");

const Box = @import("Box.zig");
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

    // Add listeners that are active over the view's entire lifetime
    self.listen_destroy.notify = handleDestroy;
    c.wl_signal_add(&self.wlr_xdg_surface.events.destroy, &self.listen_destroy);

    self.listen_map.notify = handleMap;
    c.wl_signal_add(&self.wlr_xdg_surface.events.map, &self.listen_map);

    self.listen_unmap.notify = handleUnmap;
    c.wl_signal_add(&self.wlr_xdg_surface.events.unmap, &self.listen_unmap);
}

/// Returns true if a configure must be sent to ensure the dimensions of the
/// pending_box are applied.
pub fn needsConfigure(self: Self) bool {
    const pending_box = self.view.pending_box orelse return false;

    const wlr_xdg_toplevel: *c.wlr_xdg_toplevel = @field(
        self.wlr_xdg_surface,
        c.wlr_xdg_surface_union,
    ).toplevel;

    // Checking server_pending is sufficient here since it will be either in
    // sync with the current dimensions or be the dimensions sent with the
    // most recent configure. In both cases server_pending has the values we
    // want to check against.
    return pending_box.width != wlr_xdg_toplevel.server_pending.width or
        pending_box.height != wlr_xdg_toplevel.server_pending.height;
}

/// Send a configure event, applying the width/height of the pending box.
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
    const view = self.view;
    return c.wlr_xdg_surface_surface_at(
        self.wlr_xdg_surface,
        ox - @intToFloat(f64, view.current_box.x - view.surface_box.x),
        oy - @intToFloat(f64, view.current_box.y - view.surface_box.y),
        sx,
        sy,
    );
}

/// Return the current title of the toplevel. May be an empty string.
pub fn getTitle(self: Self) [*:0]const u8 {
    const wlr_xdg_toplevel: *c.wlr_xdg_toplevel = @field(
        self.wlr_xdg_surface,
        c.wlr_xdg_surface_union,
    ).toplevel;
    return wlr_xdg_toplevel.title orelse "NULL";
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

    for (root.server.config.float_filter.items) |filter_app_id| {
        // Make views with app_ids listed in the float filter float
        if (std.mem.eql(u8, std.mem.span(app_id), std.mem.span(filter_app_id))) {
            view.setMode(.float);
            break;
        }
    } else if ((wlr_xdg_toplevel.parent != null) or
        (state.min_width != 0 and state.min_height != 0 and
        (state.min_width == state.max_width or state.min_height == state.max_height)))
    {
        // If the toplevel has a parent or is of fixed size make it float
        view.setMode(.float);
    }

    // If the toplevel has no parent, inform it that it is tiled. This
    // prevents firefox, for example, from drawing shadows around itself.
    if (wlr_xdg_toplevel.parent == null)
        _ = c.wlr_xdg_toplevel_set_tiled(
            self.wlr_xdg_surface,
            c.WLR_EDGE_LEFT | c.WLR_EDGE_RIGHT | c.WLR_EDGE_TOP | c.WLR_EDGE_BOTTOM,
        );

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
fn handleCommit(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_commit", listener.?);
    const view = self.view;

    var wlr_box: c.wlr_box = undefined;
    c.wlr_xdg_surface_get_geometry(self.wlr_xdg_surface, &wlr_box);
    const new_box = Box.fromWlrBox(wlr_box);

    // If we have sent a configure changing the size
    if (view.pending_serial) |s| {
        // Update the stored dimensions of the surface
        view.surface_box = new_box;

        if (s == self.wlr_xdg_surface.configure_serial) {
            // If this commit is in response to our configure, notify the
            // transaction code.
            view.output.root.notifyConfigured();
            view.pending_serial = null;
        } else {
            // If the client has not yet acked our configure, we need to send a
            // frame done event so that it commits another buffer. These
            // buffers won't be rendered since we are still rendering our
            // stashed buffer from when the transaction started.
            view.sendFrameDone();
        }
    } else {
        // TODO: handle unexpected change in dimensions
        if (!std.meta.eql(view.surface_box, new_box))
            log.err(.xdg_shell, "view changed size unexpectedly", .{});
        view.surface_box = new_box;
    }
}

/// Called when a new xdg popup is requested by the client
fn handleNewPopup(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_new_popup", listener.?);
    const wlr_xdg_popup = util.voidCast(c.wlr_xdg_popup, data.?);

    // This will free itself on destroy
    var xdg_popup = util.gpa.create(XdgPopup) catch unreachable;
    xdg_popup.init(self.view.output, &self.view.current_box, wlr_xdg_popup);
}
