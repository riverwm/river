const std = @import("std");
const c = @import("c.zig").c;

pub const View = struct {
    server: *Server,
    wlr_xdg_surface: *c.wlr_xdg_surface,

    listen_map: c.wl_listener,
    listen_unmap: c.wl_listener,
    listen_destroy: c.wl_listener,
    // listen_request_move: c.wl_listener,
    // listen_request_resize: c.wl_listener,

    mapped: bool,
    x: c_int,
    y: c_int,

    pub fn init(server: *Server, wlr_xdg_surface: *c.wlr_xdg_surface) @This() {
        var view = @This(){
            .server = server,
            .wlr_xdg_surface = wlr_xdg_surface,
            .listen_map = c.wl_listener{
                .link = undefined,
                .notify = handle_map,
            },
            .listen_unmap = c.wl_listener{
                .link = undefined,
                .notify = handle_unmap,
            },
            .listen_destroy = c.wl_listener{
                .link = undefined,
                .notify = handle_destroy,
            },
            // .listen_request_move = c.wl_listener{
            //     .link = undefined,
            //     .notify = handle_request_move,
            // },
            // .listen_request_resize = c.wl_listener{
            //     .link = undefined,
            //     .notify = handle_request_resize,
            // },
        };

        // Listen to the various events it can emit
        c.wl_signal_add(&xdg_surface.*.events.map, &view.*.listen_map);
        c.wl_signal_add(&xdg_surface.*.events.unmap, &view.*.listen_unmap);
        c.wl_signal_add(&xdg_surface.*.events.destroy, &view.*.listen_destroy);

        // var toplevel = xdg_surface.*.unnamed_160.toplevel;
        // c.wl_signal_add(&toplevel.*.events.request_move, &view.*.request_move);
        // c.wl_signal_add(&toplevel.*.events.request_resize, &view.*.request_resize);

        return view;
    }

    fn handle_map(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
        // Called when the surface is mapped, or ready to display on-screen.
        var view = @fieldParentPtr(View, "map", listener);
        view.*.mapped = true;
        focus_view(view, view.*.xdg_surface.*.surface);
    }

    fn handle_unmap(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
        var view = @fieldParentPtr(View, "unmap", listener);
        view.*.mapped = false;
    }

    fn handle_destroy(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
        var view = @fieldParentPtr(View, "destroy", listener);
        var server = view.*.server;
        const idx = for (server.*.views.span()) |*v, i| {
            if (v == view) {
                break i;
            }
        } else return;
        _ = server.*.views.orderedRemove(idx);
    }

    // fn xdg_toplevel_request_move(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
    //     // ignore for now
    // }

    // fn xdg_toplevel_request_resize(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
    //     // ignore for now
    // }

    fn focus_view(view: *View, surface: *c.wlr_surface) void {
        const server = view.server;
        const seat = server.*.seat;
        const prev_surface = seat.*.keyboard_state.focused_surface;

        if (prev_surface == surface) {
            // Don't re-focus an already focused surface.
            return;
        }

        if (prev_surface != null) {
            // Deactivate the previously focused surface. This lets the client know
            // it no longer has focus and the client will repaint accordingly, e.g.
            // stop displaying a caret.
            var prev_xdg_surface = c.wlr_xdg_surface_from_wlr_surface(prev_surface);
            _ = c.wlr_xdg_toplevel_set_activated(prev_xdg_surface, false);
        }

        // Find the index
        const idx = for (server.*.views.span()) |*v, i| {
            if (v == view) {
                break i;
            }
        } else unreachable;

        // Move the view to the front
        server.*.views.append(server.*.views.orderedRemove(idx)) catch unreachable;

        var moved_view = &server.*.views.span()[server.*.views.span().len - 1];

        // Activate the new surface
        _ = c.wlr_xdg_toplevel_set_activated(moved_view.*.xdg_surface, true);

        // Tell the seat to have the keyboard enter this surface. wlroots will keep
        // track of this and automatically send key events to the appropriate
        // clients without additional work on your part.
        var keyboard = c.wlr_seat_get_keyboard(seat);
        c.wlr_seat_keyboard_notify_enter(seat, moved_view.*.xdg_surface.*.surface, &keyboard.*.keycodes, keyboard.*.num_keycodes, &keyboard.*.modifiers);
    }

    fn is_at(self: *@This(), lx: f64, ly: f64, surface: *?*c.wlr_surface, sx: *f64, sy: *f64) bool {
        // XDG toplevels may have nested surfaces, such as popup windows for context
        // menus or tooltips. This function tests if any of those are underneath the
        // coordinates lx and ly (in output Layout Coordinates). If so, it sets the
        // surface pointer to that wlr_surface and the sx and sy coordinates to the
        // coordinates relative to that surface's top-left corner.
        var view_sx = lx - @intToFloat(f64, view.*.x);
        var view_sy = ly - @intToFloat(f64, view.*.y);

        // This variable seems to have been unsued in TinyWL
        // struct wlr_surface_state *state = &view->xdg_surface->surface->current;

        var _sx: f64 = undefined;
        var _sy: f64 = undefined;
        var _surface = c.wlr_xdg_surface_surface_at(view.*.xdg_surface, view_sx, view_sy, &_sx, &_sy);

        if (_surface) |surface_at| {
            sx.* = _sx;
            sy.* = _sy;
            surface.* = surface_at;
            return true;
        }

        return false;
    }
};
