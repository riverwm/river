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

const View = @import("View.zig");
const XwaylandView = @import("XwaylandView.zig");
const ViewStack = @import("view_stack.zig").ViewStack;

const log = std.log.scoped(.xwayland);

/// The corresponding wlroots object
xwayland_surface: *wlr.XwaylandSurface,

// Listeners that are always active over the view's lifetime
request_configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) =
    wl.Listener(*wlr.XwaylandSurface.event.Configure).init(handleRequestConfigure),
destroy: wl.Listener(*wlr.XwaylandSurface) = wl.Listener(*wlr.XwaylandSurface).init(handleDestroy),
map: wl.Listener(*wlr.XwaylandSurface) = wl.Listener(*wlr.XwaylandSurface).init(handleMap),
unmap: wl.Listener(*wlr.XwaylandSurface) = wl.Listener(*wlr.XwaylandSurface).init(handleUnmap),
set_override_redirect: wl.Listener(*wlr.XwaylandSurface) =
    wl.Listener(*wlr.XwaylandSurface).init(handleSetOverrideRedirect),

/// The override redirect surface will add itself to the list in Root when it is mapped.
pub fn create(xwayland_surface: *wlr.XwaylandSurface) error{OutOfMemory}!*Self {
    const node = try util.gpa.create(std.TailQueue(Self).Node);
    const self = &node.data;

    self.* = .{ .xwayland_surface = xwayland_surface };
    // This must be set to 0 for usage in View.fromWlrSurface()
    xwayland_surface.data = 0;

    // Add listeners that are active over the the entire lifetime
    xwayland_surface.events.request_configure.add(&self.request_configure);
    xwayland_surface.events.destroy.add(&self.destroy);
    xwayland_surface.events.map.add(&self.map);
    xwayland_surface.events.unmap.add(&self.unmap);
    xwayland_surface.events.set_override_redirect.add(&self.set_override_redirect);

    return self;
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
    self.set_override_redirect.link.remove();

    // Deallocate the node
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    util.gpa.destroy(node);
}

/// Called when the xwayland surface is mapped, or ready to display on-screen.
pub fn handleMap(listener: *wl.Listener(*wlr.XwaylandSurface), _: *wlr.XwaylandSurface) void {
    const self = @fieldParentPtr(Self, "map", listener);

    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    server.root.xwayland_override_redirect_views.prepend(node);

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

/// Called when the surface is unmapped and will no longer be displayed.
fn handleUnmap(listener: *wl.Listener(*wlr.XwaylandSurface), _: *wlr.XwaylandSurface) void {
    const self = @fieldParentPtr(Self, "unmap", listener);

    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    server.root.xwayland_override_redirect_views.remove(node);

    // If the unmapped surface is currently focused, pass keyboard focus
    // to the most appropriate surface.
    var seat_it = server.input_manager.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        const seat = &seat_node.data;
        switch (seat.focused) {
            .view => |focused| if (focused.impl == .xwayland_view and
                focused.impl.xwayland_view.xwayland_surface.pid == self.xwayland_surface.pid and
                seat.wlr_seat.keyboard_state.focused_surface == self.xwayland_surface.surface)
            {
                seat.keyboardEnterOrLeave(focused.surface.?);
            },
            .xwayland_override_redirect => |focused| if (focused == self) seat.focus(null),
            .layer, .lock_surface, .none => {},
        }
    }

    server.root.startTransaction();
}

fn handleSetOverrideRedirect(
    listener: *wl.Listener(*wlr.XwaylandSurface),
    xwayland_surface: *wlr.XwaylandSurface,
) void {
    const self = @fieldParentPtr(Self, "set_override_redirect", listener);

    log.debug("xwayland surface unset override redirect", .{});

    assert(!xwayland_surface.override_redirect);

    if (xwayland_surface.mapped) handleUnmap(&self.unmap, xwayland_surface);
    handleDestroy(&self.destroy, xwayland_surface);

    const output = server.input_manager.defaultSeat().focused_output;
    const xwayland_view = XwaylandView.create(output, xwayland_surface) catch {
        log.err("out of memory", .{});
        return;
    };

    if (xwayland_surface.mapped) {
        XwaylandView.handleMap(&xwayland_view.map, xwayland_surface);
    }
}
