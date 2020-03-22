const std = @import("std");
const c = @import("c.zig").c;

pub const View = struct {
    server: *Server,
    xdg_surface: *c.wlr_xdg_surface,
    map: c.wl_listener,
    unmap: c.wl_listener,
    destroy: c.wl_listener,
    request_move: c.wl_listener,
    request_resize: c.wl_listener,
    mapped: bool,
    x: c_int,
    y: c_int,
};

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

fn view_at(view: *View, lx: f64, ly: f64, surface: *?*c.wlr_surface, sx: *f64, sy: *f64) bool {
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

fn desktop_view_at(server: *Server, lx: f64, ly: f64, surface: *?*c.wlr_surface, sx: *f64, sy: *f64) ?*View {
    // This iterates over all of our surfaces and attempts to find one under the
    // cursor. This relies on server.*.views being ordered from top-to-bottom.
    for (server.*.views.span()) |*view| {
        if (view_at(view, lx, ly, surface, sx, sy)) {
            return view;
        }
    }
    return null;
}
