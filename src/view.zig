const std = @import("std");
const c = @import("c.zig").c;

const Server = @import("server.zig").Server;

pub const View = struct {
    const Self = @This();

    server: *Server,
    wlr_xdg_surface: *c.wlr_xdg_surface,

    mapped: bool,
    x: c_int,
    y: c_int,

    listen_map: c.wl_listener,
    listen_unmap: c.wl_listener,
    listen_destroy: c.wl_listener,
    // listen_request_move: c.wl_listener,
    // listen_request_resize: c.wl_listener,

    pub fn init(self: *Self, server: *Server, wlr_xdg_surface: *c.wlr_xdg_surface) void {
        self.server = server;
        self.wlr_xdg_surface = wlr_xdg_surface;

        self.mapped = false;
        self.x = 0;
        self.y = 0;

        self.listen_map.notify = handle_map;
        c.wl_signal_add(&self.wlr_xdg_surface.events.map, &self.listen_map);

        self.listen_unmap.notify = handle_unmap;
        c.wl_signal_add(&self.wlr_xdg_surface.events.unmap, &self.listen_unmap);

        self.listen_destroy.notify = handle_destroy;
        c.wl_signal_add(&self.wlr_xdg_surface.events.destroy, &self.listen_destroy);

        // const toplevel = xdg_surface.unnamed_160.toplevel;
        // c.wl_signal_add(&toplevel.events.request_move, &view.request_move);
        // c.wl_signal_add(&toplevel.events.request_resize, &view.request_resize);
    }

    fn handle_map(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // Called when the surface is mapped, or ready to display on-screen.
        const view = @fieldParentPtr(View, "listen_map", listener.?);
        view.mapped = true;
        view.focus(view.wlr_xdg_surface.surface);
    }

    fn handle_unmap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const view = @fieldParentPtr(View, "listen_unmap", listener.?);
        view.mapped = false;
    }

    fn handle_destroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const view = @fieldParentPtr(View, "listen_destroy", listener.?);
        const server = view.server;

        var it = server.views.first;
        const target = while (it) |node| : (it = node.next) {
            if (&node.data == view) {
                break node;
            }
        } else unreachable;

        server.views.remove(target);
        server.views.destroyNode(target, server.allocator);
    }

    // fn xdg_toplevel_request_move(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    //     // ignore for now
    // }

    // fn xdg_toplevel_request_resize(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    //     // ignore for now
    // }

    fn focus(self: *Self, surface: *c.wlr_surface) void {
        const server = self.server;
        const wlr_seat = server.seat.wlr_seat;
        const prev_surface = wlr_seat.keyboard_state.focused_surface;

        if (prev_surface == surface) {
            // Don't re-focus an already focused surface.
            return;
        }

        if (prev_surface != null) {
            // Deactivate the previously focused surface. This lets the client know
            // it no longer has focus and the client will repaint accordingly, e.g.
            // stop displaying a caret.
            const prev_xdg_surface = c.wlr_xdg_surface_from_wlr_surface(prev_surface);
            _ = c.wlr_xdg_toplevel_set_activated(prev_xdg_surface, false);
        }

        // Find the node
        var it = server.views.first;
        const target = while (it) |node| : (it = node.next) {
            if (&node.data == self) {
                break node;
            }
        } else unreachable;

        // Move the view to the front
        server.views.remove(target);
        server.views.prepend(target);

        // Activate the new surface
        _ = c.wlr_xdg_toplevel_set_activated(self.wlr_xdg_surface, true);

        // Tell the seat to have the keyboard enter this surface. wlroots will keep
        // track of this and automatically send key events to the appropriate
        // clients without additional work on your part.
        const keyboard: *c.wlr_keyboard = c.wlr_seat_get_keyboard(wlr_seat);
        c.wlr_seat_keyboard_notify_enter(
            wlr_seat,
            self.wlr_xdg_surface.surface,
            &keyboard.keycodes,
            keyboard.num_keycodes,
            &keyboard.modifiers,
        );
    }

    fn is_at(self: *Self, lx: f64, ly: f64, surface: *?*c.wlr_surface, sx: *f64, sy: *f64) bool {
        // XDG toplevels may have nested surfaces, such as popup windows for context
        // menus or tooltips. This function tests if any of those are underneath the
        // coordinates lx and ly (in output Layout Coordinates). If so, it sets the
        // surface pointer to that wlr_surface and the sx and sy coordinates to the
        // coordinates relative to that surface's top-left corner.
        const view_sx = lx - @intToFloat(f64, self.x);
        const view_sy = ly - @intToFloat(f64, self.y);

        // This variable seems to have been unsued in TinyWL
        // struct wlr_surface_state *state = &view->xdg_surface->surface->current;

        var _sx: f64 = undefined;
        var _sy: f64 = undefined;
        const _surface = c.wlr_xdg_surface_surface_at(self.wlr_xdg_surface, view_sx, view_sy, &_sx, &_sy);

        if (_surface) |surface_at| {
            sx.* = _sx;
            sy.* = _sy;
            surface.* = surface_at;
            return true;
        }

        return false;
    }
};
