const std = @import("std");
const c = @import("c.zig").c;

fn xdg_surface_map(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
    // Called when the surface is mapped, or ready to display on-screen.
    var view = @fieldParentPtr(View, "map", listener);
    view.*.mapped = true;
    focus_view(view, view.*.xdg_surface.*.surface);
}

fn xdg_surface_unmap(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
    var view = @fieldParentPtr(View, "unmap", listener);
    view.*.mapped = false;
}

fn xdg_surface_destroy(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
    var view = @fieldParentPtr(View, "destroy", listener);
    var server = view.*.server;
    const idx = for (server.*.views.span()) |*v, i| {
        if (v == view) {
            break i;
        }
    } else return;
    _ = server.*.views.orderedRemove(idx);
}

fn xdg_toplevel_request_move(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
    // ignore for now
}

fn xdg_toplevel_request_resize(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
    // ignore for now
}

fn server_new_xdg_surface(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is raised when wlr_xdg_shell receives a new xdg surface from a
    // client, either a toplevel (application window) or popup.
    var server = @fieldParentPtr(Server, "new_xdg_surface", listener);
    var xdg_surface = @ptrCast(*c.wlr_xdg_surface, @alignCast(@alignOf(*c.wlr_xdg_surface), data));

    if (xdg_surface.*.role != c.enum_wlr_xdg_surface_role.WLR_XDG_SURFACE_ROLE_TOPLEVEL) {
        return;
    }

    // Allocate a View for this surface
    server.*.views.append(undefined) catch unreachable;
    var view = &server.*.views.span()[server.*.views.span().len - 1];

    view.*.server = server;
    view.*.xdg_surface = xdg_surface;

    // Listen to the various events it can emit
    view.*.map.notify = xdg_surface_map;
    c.wl_signal_add(&xdg_surface.*.events.map, &view.*.map);

    view.*.unmap.notify = xdg_surface_unmap;
    c.wl_signal_add(&xdg_surface.*.events.unmap, &view.*.unmap);

    view.*.destroy.notify = xdg_surface_destroy;
    c.wl_signal_add(&xdg_surface.*.events.destroy, &view.*.destroy);

    var toplevel = xdg_surface.*.unnamed_160.toplevel;
    view.*.request_move.notify = xdg_toplevel_request_move;
    c.wl_signal_add(&toplevel.*.events.request_move, &view.*.request_move);

    view.*.request_resize.notify = xdg_toplevel_request_resize;
    c.wl_signal_add(&toplevel.*.events.request_resize, &view.*.request_resize);
}
