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
const math = std.math;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;

const Box = @import("Box.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XdgPopup = @import("XdgPopup.zig");

/// The view this xwayland view implements
view: *View,

/// The corresponding wlroots object
xwayland_surface: *wlr.XwaylandSurface,

// Listeners that are always active over the view's lifetime
destroy: wl.Listener(*wlr.XwaylandSurface) = wl.Listener(*wlr.XwaylandSurface).init(handleDestroy),
map: wl.Listener(*wlr.XwaylandSurface) = wl.Listener(*wlr.XwaylandSurface).init(handleMap),
unmap: wl.Listener(*wlr.XwaylandSurface) = wl.Listener(*wlr.XwaylandSurface).init(handleUnmap),
request_configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) =
    wl.Listener(*wlr.XwaylandSurface.event.Configure).init(handleRequestConfigure),

// Listeners that are only active while the view is mapped
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),
set_title: wl.Listener(*wlr.XwaylandSurface) = wl.Listener(*wlr.XwaylandSurface).init(handleSetTitle),
set_class: wl.Listener(*wlr.XwaylandSurface) = wl.Listener(*wlr.XwaylandSurface).init(handleSetClass),
request_fullscreen: wl.Listener(*wlr.XwaylandSurface) =
    wl.Listener(*wlr.XwaylandSurface).init(handleRequestFullscreen),
request_minimize: wl.Listener(*wlr.XwaylandSurface.event.Minimize) =
    wl.Listener(*wlr.XwaylandSurface.event.Minimize).init(handleRequestMinimize),

pub fn init(self: *Self, view: *View, xwayland_surface: *wlr.XwaylandSurface) void {
    self.* = .{ .view = view, .xwayland_surface = xwayland_surface };
    xwayland_surface.data = @ptrToInt(self);

    // Add listeners that are active over the view's entire lifetime
    xwayland_surface.events.destroy.add(&self.destroy);
    xwayland_surface.events.map.add(&self.map);
    xwayland_surface.events.unmap.add(&self.unmap);
    xwayland_surface.events.request_configure.add(&self.request_configure);
}

pub fn needsConfigure(self: Self) bool {
    const output = self.view.output;
    const output_box = server.root.output_layout.getBox(output.wlr_output).?;
    return self.xwayland_surface.x != self.view.pending.box.x + output_box.x or
        self.xwayland_surface.y != self.view.pending.box.y + output_box.y or
        self.xwayland_surface.width != self.view.pending.box.width or
        self.xwayland_surface.height != self.view.pending.box.height;
}

/// Apply pending state. Note: we don't set View.serial as
/// shouldTrackConfigure() is always false for xwayland views.
pub fn configure(self: Self) void {
    const output = self.view.output;
    const output_box = server.root.output_layout.getBox(output.wlr_output).?;

    const state = &self.view.pending;
    self.xwayland_surface.configure(
        @intCast(i16, state.box.x + output_box.x),
        @intCast(i16, state.box.y + output_box.y),
        @intCast(u16, state.box.width),
        @intCast(u16, state.box.height),
    );
}

/// Close the view. This will lead to the unmap and destroy events being sent
pub fn close(self: Self) void {
    self.xwayland_surface.close();
}

pub fn setActivated(self: Self, activated: bool) void {
    // See comment on handleRequestMinimize() for details
    if (activated and self.xwayland_surface.minimized) {
        self.xwayland_surface.setMinimized(false);
    }
    self.xwayland_surface.activate(activated);
    self.xwayland_surface.restack(null, .above);
}

pub fn setFullscreen(self: Self, fullscreen: bool) void {
    self.xwayland_surface.setFullscreen(fullscreen);
}

/// Return the surface at output coordinates ox, oy and set sx, sy to the
/// corresponding surface-relative coordinates, if there is a surface.
pub fn surfaceAt(self: Self, ox: f64, oy: f64, sx: *f64, sy: *f64) ?*wlr.Surface {
    return self.xwayland_surface.surface.?.surfaceAt(
        ox - @intToFloat(f64, self.view.current.box.x),
        oy - @intToFloat(f64, self.view.current.box.y),
        sx,
        sy,
    );
}

/// Get the current title of the xwayland surface if any.
pub fn getTitle(self: Self) ?[*:0]const u8 {
    return self.xwayland_surface.title;
}
/// X11 clients don't have an app_id but the class serves a similar role.
/// Get the current class of the xwayland surface if any.
pub fn getAppId(self: Self) ?[*:0]const u8 {
    return self.xwayland_surface.class;
}

/// Return bounds on the dimensions of the view
pub fn getConstraints(self: Self) View.Constraints {
    const hints = self.xwayland_surface.size_hints orelse return .{
        .min_width = View.min_size,
        .min_height = View.min_size,
        .max_width = math.maxInt(u32),
        .max_height = math.maxInt(u32),
    };
    return .{
        .min_width = @intCast(u32, math.max(hints.min_width, View.min_size)),
        .min_height = @intCast(u32, math.max(hints.min_height, View.min_size)),

        .max_width = if (hints.max_width > 0)
            math.max(@intCast(u32, hints.max_width), View.min_size)
        else
            math.maxInt(u32),

        .max_height = if (hints.max_height > 0)
            math.max(@intCast(u32, hints.max_height), View.min_size)
        else
            math.maxInt(u32),
    };
}

/// Called when the xwayland surface is destroyed
fn handleDestroy(listener: *wl.Listener(*wlr.XwaylandSurface), _: *wlr.XwaylandSurface) void {
    const self = @fieldParentPtr(Self, "destroy", listener);

    // Remove listeners that are active for the entire lifetime of the view
    self.destroy.link.remove();
    self.map.link.remove();
    self.unmap.link.remove();
    self.request_configure.link.remove();

    self.view.destroy();
}

/// Called when the xwayland surface is mapped, or ready to display on-screen.
fn handleMap(listener: *wl.Listener(*wlr.XwaylandSurface), xwayland_surface: *wlr.XwaylandSurface) void {
    const self = @fieldParentPtr(Self, "map", listener);
    const view = self.view;

    // Add listeners that are only active while mapped
    const surface = xwayland_surface.surface.?;
    surface.events.commit.add(&self.commit);
    xwayland_surface.events.set_title.add(&self.set_title);
    xwayland_surface.events.set_class.add(&self.set_class);
    xwayland_surface.events.request_fullscreen.add(&self.request_fullscreen);
    xwayland_surface.events.request_minimize.add(&self.request_minimize);

    view.surface = surface;
    self.view.surface_box = .{
        .x = 0,
        .y = 0,
        .width = @intCast(u32, surface.current.width),
        .height = @intCast(u32, surface.current.height),
    };

    // Use the view's "natural" size centered on the output as the default
    // floating dimensions
    view.float_box.width = self.xwayland_surface.width;
    view.float_box.height = self.xwayland_surface.height;
    view.float_box.x = math.max(0, @divTrunc(@intCast(i32, view.output.usable_box.width) -
        @intCast(i32, view.float_box.width), 2));
    view.float_box.y = math.max(0, @divTrunc(@intCast(i32, view.output.usable_box.height) -
        @intCast(i32, view.float_box.height), 2));

    const has_fixed_size = if (self.xwayland_surface.size_hints) |size_hints|
        size_hints.min_width != 0 and size_hints.min_height != 0 and
            (size_hints.min_width == size_hints.max_width or size_hints.min_height == size_hints.max_height)
    else
        false;

    if (self.xwayland_surface.parent != null or has_fixed_size) {
        // If the toplevel has a parent or has a fixed size make it float
        view.current.float = true;
        view.pending.float = true;
        view.pending.box = view.float_box;
    } else if (server.config.shouldFloat(view)) {
        view.current.float = true;
        view.pending.float = true;
        view.pending.box = view.float_box;
    }

    view.map() catch {
        std.log.err("out of memory", .{});
        surface.resource.getClient().postNoMemory();
    };
}

/// Called when the surface is unmapped and will no longer be displayed.
fn handleUnmap(listener: *wl.Listener(*wlr.XwaylandSurface), _: *wlr.XwaylandSurface) void {
    const self = @fieldParentPtr(Self, "unmap", listener);

    // Remove listeners that are only active while mapped
    self.commit.link.remove();
    self.set_title.link.remove();
    self.set_class.link.remove();
    self.request_fullscreen.link.remove();
    self.request_minimize.link.remove();

    self.view.unmap();
}

fn handleRequestConfigure(
    listener: *wl.Listener(*wlr.XwaylandSurface.event.Configure),
    event: *wlr.XwaylandSurface.event.Configure,
) void {
    const self = @fieldParentPtr(Self, "request_configure", listener);

    // If unmapped, let the client do whatever it wants
    if (self.view.surface == null) {
        self.xwayland_surface.configure(event.x, event.y, event.width, event.height);
        return;
    }

    // Allow xwayland views to set their own dimensions (but not position) if floating
    if (self.view.pending.float) {
        self.view.pending.box.width = event.width;
        self.view.pending.box.height = event.height;
    }
    self.configure();
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), surface: *wlr.Surface) void {
    const self = @fieldParentPtr(Self, "commit", listener);

    self.view.output.damage.?.addWhole();

    self.view.surface_box = .{
        .x = 0,
        .y = 0,
        .width = @intCast(u32, surface.current.width),
        .height = @intCast(u32, surface.current.height),
    };
}

fn handleSetTitle(listener: *wl.Listener(*wlr.XwaylandSurface), _: *wlr.XwaylandSurface) void {
    const self = @fieldParentPtr(Self, "set_title", listener);
    self.view.notifyTitle();
}

fn handleSetClass(listener: *wl.Listener(*wlr.XwaylandSurface), _: *wlr.XwaylandSurface) void {
    const self = @fieldParentPtr(Self, "set_class", listener);
    self.view.notifyAppId();
}

fn handleRequestFullscreen(listener: *wl.Listener(*wlr.XwaylandSurface), xwayland_surface: *wlr.XwaylandSurface) void {
    const self = @fieldParentPtr(Self, "request_fullscreen", listener);
    self.view.pending.fullscreen = xwayland_surface.fullscreen;
    self.view.applyPending();
}

/// Some X11 clients will minimize themselves regardless of how we respond.
/// Therefore to ensure they don't get stuck in this minimized state we tell
/// them their request has been honored without actually doing anything and
/// unminimize them if they gain focus while minimized.
fn handleRequestMinimize(
    listener: *wl.Listener(*wlr.XwaylandSurface.event.Minimize),
    event: *wlr.XwaylandSurface.event.Minimize,
) void {
    const self = @fieldParentPtr(Self, "request_minimize", listener);
    self.xwayland_surface.setMinimized(event.minimize);
}
