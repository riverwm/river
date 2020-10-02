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
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const util = @import("util.zig");

const Box = @import("Box.zig");
const Seat = @import("Seat.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XdgPopup = @import("XdgPopup.zig");

const log = std.log.scoped(.xdg_shell);

/// The view this xdg toplevel implements
view: *View,

/// The corresponding wlroots object
xdg_surface: *wlr.XdgSurface,

// Listeners that are always active over the view's lifetime
destroy: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(handleDestroy),
map: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(handleMap),
unmap: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(handleUnmap),

// Listeners that are only active while the view is mapped
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),
new_popup: wl.Listener(*wlr.XdgPopup) = wl.Listener(*wlr.XdgPopup).init(handleNewPopup),
// zig fmt: off
request_fullscreen: wl.Listener(*wlr.XdgToplevel.event.SetFullscreen) =
    wl.Listener(*wlr.XdgToplevel.event.SetFullscreen).init(handleRequestFullscreen),
request_move: wl.Listener(*wlr.XdgToplevel.event.Move) =
    wl.Listener(*wlr.XdgToplevel.event.Move).init(handleRequestMove),
request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) =
    wl.Listener(*wlr.XdgToplevel.event.Resize).init(handleRequestResize),
// zig fmt: on
set_title: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(handleSetTitle),
set_app_id: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(handleSetAppId),

pub fn init(self: *Self, view: *View, xdg_surface: *wlr.XdgSurface) void {
    self.* = .{ .view = view, .xdg_surface = xdg_surface };
    xdg_surface.data = @ptrToInt(self);

    // Add listeners that are active over the view's entire lifetime
    self.xdg_surface.events.destroy.add(&self.destroy);
    self.xdg_surface.events.map.add(&self.map);
    self.xdg_surface.events.unmap.add(&self.unmap);
}

pub fn deinit(self: *Self) void {
    if (self.view.surface != null) {
        // Remove listeners that are active for the entire lifetime of the view
        self.destroy.link.remove();
        self.map.link.remove();
        self.unmap.link.remove();
    }
}

/// Returns true if a configure must be sent to ensure the dimensions of the
/// pending_box are applied.
pub fn needsConfigure(self: Self) bool {
    const server_pending = &self.xdg_surface.role_data.toplevel.server_pending;
    const state = &self.view.pending;

    // Checking server_pending is sufficient here since it will be either in
    // sync with the current dimensions or be the dimensions sent with the
    // most recent configure. In both cases server_pending has the values we
    // want to check against.
    return (state.focus != 0) != server_pending.activated or
        state.box.width != server_pending.width or
        state.box.height != server_pending.height;
}

/// Send a configure event, applying the pending state of the view.
pub fn configure(self: Self) void {
    const toplevel = self.xdg_surface.role_data.toplevel;
    const state = &self.view.pending;
    _ = toplevel.setActivated(state.focus != 0);
    _ = toplevel.setFullscreen(state.fullscreen);
    self.view.pending_serial = toplevel.setSize(state.box.width, state.box.height);
}

/// Close the view. This will lead to the unmap and destroy events being sent
pub fn close(self: Self) void {
    self.xdg_surface.role_data.toplevel.sendClose();
}

pub inline fn forEachPopupSurface(
    self: Self,
    comptime T: type,
    iterator: fn (surface: *wlr.Surface, sx: c_int, sy: c_int, data: T) callconv(.C) void,
    user_data: T,
) void {
    self.xdg_surface.forEachPopupSurface(T, iterator, user_data);
}

/// Return the surface at output coordinates ox, oy and set sx, sy to the
/// corresponding surface-relative coordinates, if there is a surface.
pub fn surfaceAt(self: Self, ox: f64, oy: f64, sx: *f64, sy: *f64) ?*wlr.Surface {
    const view = self.view;
    return self.xdg_surface.surfaceAt(
        ox - @intToFloat(f64, view.current.box.x - view.surface_box.x),
        oy - @intToFloat(f64, view.current.box.y - view.surface_box.y),
        sx,
        sy,
    );
}

/// Return the current title of the toplevel if any.
pub fn getTitle(self: Self) ?[*:0]const u8 {
    return self.xdg_surface.role_data.toplevel.title;
}

/// Return the current app_id of the toplevel if any .
pub fn getAppId(self: Self) ?[*:0]const u8 {
    return self.xdg_surface.role_data.toplevel.app_id;
}

/// Return bounds on the dimensions of the toplevel.
pub fn getConstraints(self: Self) View.Constraints {
    const state = &self.xdg_surface.role_data.toplevel.current;
    return .{
        .min_width = std.math.max(state.min_width, View.min_size),
        .max_width = if (state.max_width > 0) state.max_width else std.math.maxInt(u32),
        .min_height = std.math.max(state.min_height, View.min_size),
        .max_height = if (state.max_height > 0) state.max_height else std.math.maxInt(u32),
    };
}

/// Called when the xdg surface is destroyed
fn handleDestroy(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
    const self = @fieldParentPtr(Self, "destroy", listener);
    self.deinit();
    self.view.surface = null;
}

/// Called when the xdg surface is mapped, or ready to display on-screen.
fn handleMap(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
    const self = @fieldParentPtr(Self, "map", listener);
    const view = self.view;
    const root = view.output.root;
    const toplevel = self.xdg_surface.role_data.toplevel;

    // Add listeners that are only active while mapped
    self.xdg_surface.surface.events.commit.add(&self.commit);
    self.xdg_surface.events.new_popup.add(&self.new_popup);
    toplevel.events.request_fullscreen.add(&self.request_fullscreen);
    toplevel.events.request_move.add(&self.request_move);
    toplevel.events.request_resize.add(&self.request_resize);
    toplevel.events.set_title.add(&self.set_title);
    toplevel.events.set_app_id.add(&self.set_app_id);

    view.surface = self.xdg_surface.surface;

    // Use the view's initial size centered on the output as the default
    // floating dimensions
    var initial_box: wlr.Box = undefined;
    self.xdg_surface.getGeometry(&initial_box);
    view.float_box.width = @intCast(u32, initial_box.width);
    view.float_box.height = @intCast(u32, initial_box.height);
    view.float_box.x = std.math.max(0, @divTrunc(@intCast(i32, view.output.usable_box.width) -
        @intCast(i32, view.float_box.width), 2));
    view.float_box.y = std.math.max(0, @divTrunc(@intCast(i32, view.output.usable_box.height) -
        @intCast(i32, view.float_box.height), 2));

    // Also use the view's  "natural" size as the initial regular dimensions,
    // for the case that it does not get arranged by a lyaout.
    view.pending.box = view.float_box;

    const state = &toplevel.current;
    const has_fixed_size = state.min_width != 0 and state.min_height != 0 and
        (state.min_width == state.max_width or state.min_height == state.max_height);
    const app_id: [*:0]const u8 = if (toplevel.app_id) |id| id else "NULL";

    if (toplevel.parent != null or has_fixed_size) {
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

    // If the toplevel has an app_id which is not configured to use client side
    // decorations, inform it that it is tiled.
    for (root.server.config.csd_filter.items) |filter_app_id| {
        if (std.mem.eql(u8, std.mem.span(app_id), filter_app_id)) {
            view.draw_borders = false;
            break;
        }
    } else {
        _ = toplevel.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
    }

    view.map();
}

/// Called when the surface is unmapped and will no longer be displayed.
fn handleUnmap(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
    const self = @fieldParentPtr(Self, "unmap", listener);
    const root = self.view.output.root;

    self.view.unmap();

    // Remove listeners that are only active while mapped
    self.commit.link.remove();
    self.new_popup.link.remove();
    self.request_fullscreen.link.remove();
    self.request_move.link.remove();
    self.request_resize.link.remove();
    self.set_title.link.remove();
}

/// Called when the surface is comitted
fn handleCommit(listener: *wl.Listener(*wlr.Surface), surface: *wlr.Surface) void {
    const self = @fieldParentPtr(Self, "commit", listener);
    const view = self.view;

    var wlr_box: wlr.Box = undefined;
    self.xdg_surface.getGeometry(&wlr_box);
    const new_box = Box.fromWlrBox(wlr_box);

    // If we have sent a configure changing the size
    if (view.pending_serial) |s| {
        // Update the stored dimensions of the surface
        view.surface_box = new_box;

        if (s == self.xdg_surface.configure_serial) {
            view.notifyConfiguredOrApplyPending();
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
            log.err("view changed size unexpectedly", .{});
        view.surface_box = new_box;
    }
}

/// Called when a new xdg popup is requested by the client
fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const self = @fieldParentPtr(Self, "new_popup", listener);

    // This will free itself on destroy
    const xdg_popup = util.gpa.create(XdgPopup) catch {
        wlr_xdg_popup.resource.postNoMemory();
        return;
    };
    xdg_popup.init(self.view.output, &self.view.current.box, wlr_xdg_popup);
}

/// Called when the client asks to be fullscreened. We always honor the request
/// for now, perhaps it should be denied in some cases in the future.
fn handleRequestFullscreen(
    listener: *wl.Listener(*wlr.XdgToplevel.event.SetFullscreen),
    event: *wlr.XdgToplevel.event.SetFullscreen,
) void {
    const self = @fieldParentPtr(Self, "request_fullscreen", listener);
    self.view.pending.fullscreen = event.fullscreen;
    self.view.applyPending();
}

/// Called when the client asks to be moved via the cursor, for example when the
/// user drags CSD titlebars.
fn handleRequestMove(
    listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
    event: *wlr.XdgToplevel.event.Move,
) void {
    const self = @fieldParentPtr(Self, "request_move", listener);
    const seat = @intToPtr(*Seat, event.seat.seat.data);
    if (self.view.pending.float or self.view.output.current.layout == null)
        seat.cursor.enterMode(.move, self.view);
}

/// Called when the client asks to be resized via the cursor.
fn handleRequestResize(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
    const self = @fieldParentPtr(Self, "request_resize", listener);
    const seat = @intToPtr(*Seat, event.seat.seat.data);
    if (self.view.pending.float or self.view.output.current.layout == null)
        seat.cursor.enterMode(.resize, self.view);
}

/// Called when the client sets / updates its title
fn handleSetTitle(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
    const self = @fieldParentPtr(Self, "set_title", listener);
    self.view.notifyTitle();
}

/// Called when the client sets / updates its app_id
fn handleSetAppId(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
    const self = @fieldParentPtr(Self, "set_app_id", listener);
    self.view.notifyAppId();
}
