// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XdgPopup = @import("XdgPopup.zig");

/// The view this xwayland view implements
view: *View,

/// The corresponding wlroots object
wlr_xwayland_surface: *c.wlr_xwayland_surface,

// Listeners that are always active over the view's lifetime
listen_destroy: c.wl_listener = undefined,
listen_map: c.wl_listener = undefined,
listen_unmap: c.wl_listener = undefined,
listen_title: c.wl_listener = undefined,

// Listeners that are only active while the view is mapped
listen_commit: c.wl_listener = undefined,

pub fn init(self: *Self, view: *View, wlr_xwayland_surface: *c.wlr_xwayland_surface) void {
    self.* = .{ .view = view, .wlr_xwayland_surface = wlr_xwayland_surface };
    wlr_xwayland_surface.data = self;

    // Add listeners that are active over the view's entire lifetime
    self.listen_destroy.notify = handleDestroy;
    c.wl_signal_add(&self.wlr_xwayland_surface.events.destroy, &self.listen_destroy);

    self.listen_map.notify = handleMap;
    c.wl_signal_add(&self.wlr_xwayland_surface.events.map, &self.listen_map);

    self.listen_unmap.notify = handleUnmap;
    c.wl_signal_add(&self.wlr_xwayland_surface.events.unmap, &self.listen_unmap);

    self.listen_title.notify = handleTitle;
    c.wl_signal_add(&self.wlr_xwayland_surface.events.set_title, &self.listen_title);
}

pub fn deinit(self: *Self) void {
    if (self.view.wlr_surface != null) {
        // Remove listeners that are active for the entire lifetime of the view
        c.wl_list_remove(&self.listen_destroy.link);
        c.wl_list_remove(&self.listen_map.link);
        c.wl_list_remove(&self.listen_unmap.link);
        c.wl_list_remove(&self.listen_title.link);
    }
}

pub fn needsConfigure(self: Self) bool {
    return self.wlr_xwayland_surface.x != self.view.pending.box.x or
        self.wlr_xwayland_surface.y != self.view.pending.box.y or
        self.wlr_xwayland_surface.width != self.view.pending.box.width or
        self.wlr_xwayland_surface.height != self.view.pending.box.height;
}

/// Apply pending state
pub fn configure(self: Self) void {
    const state = &self.view.pending;
    c.wlr_xwayland_surface_set_fullscreen(self.wlr_xwayland_surface, state.fullscreen);
    c.wlr_xwayland_surface_configure(
        self.wlr_xwayland_surface,
        @intCast(i16, state.box.x),
        @intCast(i16, state.box.y),
        @intCast(u16, state.box.width),
        @intCast(u16, state.box.height),
    );
    // Xwayland surfaces don't use serials, so we will just assume they have
    // configured the next time they commit. Set pending serial to a dummy
    // value to indicate that a transaction has started. Note: we can't just
    // call notifyConfigured() here as the transaction has not yet been fully
    // initiated.
    self.view.pending_serial = 0x66666666;
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
        ox - @intToFloat(f64, self.view.current.box.x),
        oy - @intToFloat(f64, self.view.current.box.y),
        sx,
        sy,
    );
}

/// Get the current title of the xwayland surface. May be an empty string
pub fn getTitle(self: Self) [*:0]const u8 {
    return self.wlr_xwayland_surface.title orelse "";
}

/// Return bounds on the dimensions of the view
pub fn getConstraints(self: Self) View.Constraints {
    const hints: *c.wlr_xwayland_surface_size_hints = self.wlr_xwayland_surface.size_hints orelse return .{
        .min_width = View.min_size,
        .max_width = std.math.maxInt(u32),
        .min_height = View.min_size,
        .max_height = std.math.maxInt(u32),
    };
    return .{
        .min_width = @intCast(u32, std.math.max(hints.min_width, View.min_size)),
        .max_width = if (hints.max_width > 0) @intCast(u32, hints.max_width) else std.math.maxInt(u32),
        .min_height = @intCast(u32, std.math.max(hints.min_height, View.min_size)),
        .max_height = if (hints.max_height > 0) @intCast(u32, hints.max_height) else std.math.maxInt(u32),
    };
}

/// Called when the xwayland surface is destroyed
fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_destroy", listener.?);
    self.deinit();
    self.view.wlr_surface = null;
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

    // Use the view's "natural" size centered on the output as the default
    // floating dimensions
    view.float_box.width = self.wlr_xwayland_surface.width;
    view.float_box.height = self.wlr_xwayland_surface.height;
    view.float_box.x = std.math.max(0, @divTrunc(@intCast(i32, view.output.usable_box.width) -
        @intCast(i32, view.float_box.width), 2));
    view.float_box.y = std.math.max(0, @divTrunc(@intCast(i32, view.output.usable_box.height) -
        @intCast(i32, view.float_box.height), 2));

    const size_hints = self.wlr_xwayland_surface.size_hints;
    const has_fixed_size = size_hints.*.min_width != 0 and size_hints.*.min_height != 0 and
        (size_hints.*.min_width == size_hints.*.max_width or size_hints.*.min_height == size_hints.*.max_height);
    const app_id: [*:0]const u8 = if (self.wlr_xwayland_surface.class) |id| id else "NULL";

    if (self.wlr_xwayland_surface.parent != null or has_fixed_size) {
        // If the toplevel has a parent or has a fixed size make it float
        view.current.float = true;
        view.pending.float = true;
        view.pending.box = view.float_box;
    } else {
        // Make views with app_ids listed in the float filter float
        for (root.server.config.float_filter.items) |filter_app_id| {
            if (std.mem.eql(u8, std.mem.span(app_id), std.mem.span(filter_app_id))) {
                view.current.float = true;
                view.pending.float = true;
                view.pending.box = view.float_box;
                break;
            }
        }
    }

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

    view.surface_box = Box{
        .x = 0,
        .y = 0,
        .width = @intCast(u32, self.wlr_xwayland_surface.surface.*.current.width),
        .height = @intCast(u32, self.wlr_xwayland_surface.surface.*.current.height),
    };

    // See comment in XwaylandView.configure()
    if (view.pending_serial != null) {
        view.notifyConfiguredOrApplyPending();
    }
}

/// Called then the window updates its title
fn handleTitle(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_title", listener.?);

    // Send title to all status listeners attached to a seat which focuses this view
    var seat_it = self.view.output.root.server.input_manager.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        if (seat_node.data.focused == .view and seat_node.data.focused.view == self.view) {
            var client_it = seat_node.data.status_trackers.first;
            while (client_it) |client_node| : (client_it = client_node.next) {
                client_node.data.sendFocusedView();
            }
        }
    }
}
