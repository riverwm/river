const std = @import("std");
const c = @import("c.zig").c;

pub const Server = struct {
    wl_display: *c.wl_display,
    backend: *c.wlr_backend,
    renderer: *c.wlr_renderer,
    xdg_shell: *c.wlr_xdg_shell,
    new_xdg_surface: c.wl_listener,
    views: std.ArrayList(View),

    output_layout: *c.wlr_output_layout,
    outputs: std.ArrayList(Output),
    new_output: c.wl_listener,

    pub fn init(allocator: *std.mem.Allocator) !@This() {
        var server: @This() = undefined;

        // The Wayland display is managed by libwayland. It handles accepting
        // clients from the Unix socket, manging Wayland globals, and so on.
        server.wl_display = c.wl_display_create() orelse return error.CantCreateWlDisplay;

        // The backend is a wlroots feature which abstracts the underlying input and
        // output hardware. The autocreate option will choose the most suitable
        // backend based on the current environment, such as opening an X11 window
        // if an X11 server is running. The NULL argument here optionally allows you
        // to pass in a custom renderer if wlr_renderer doesn't meet your needs. The
        // backend uses the renderer, for example, to fall back to software cursors
        // if the backend does not support hardware cursors (some older GPUs
        // don't).
        server.backend = c.zag_wlr_backend_autocreate(server.wl_display) orelse return error.CantCreateWlrBackend;

        // If we don't provide a renderer, autocreate makes a GLES2 renderer for us.
        // The renderer is responsible for defining the various pixel formats it
        // supports for shared memory, this configures that for clients.
        server.renderer = c.zag_wlr_backend_get_renderer(server.backend) orelse return error.CantGetWlrRenderer;
        c.wlr_renderer_init_wl_display(server.renderer, server.wl_display) orelse return error.CantInitWlDisplay;

        // This creates some hands-off wlroots interfaces. The compositor is
        // necessary for clients to allocate surfaces and the data device manager
        // handles the clipboard. Each of these wlroots interfaces has room for you
        // to dig your fingers in and play with their behavior if you want.
        _ = c.wlr_compositor_create(server.wl_display, server.renderer) orelse return error.CantCreateWlrCompositor;
        _ = c.wlr_data_device_manager_create(server.wl_display) orelse return error.CantCreateWlrDataDeviceManager;
    }

    pub fn handle_keybinding(self: *@This(), sym: c.xkb_keysym_t) bool {
        // Here we handle compositor keybindings. This is when the compositor is
        // processing keys, rather than passing them on to the client for its own
        // processing.
        //
        // This function assumes the proper modifier is held down.
        switch (sym) {
            c.XKB_KEY_Escape => c.wl_display_terminate(server.*.wl_display),
            c.XKB_KEY_F1 => {
                // Cycle to the next view
                //if (c.wl_list_length(&server.*.views) > 1) {
                //    const current_view = @fieldParentPtr(View, "link", server.*.views.next);
                //    const next_view = @fieldParentPtr(View, "link", current_view.*.link.next);
                //    focus_view(next_view, next_view.*.xdg_surface.*.surface);
                //    // Move the previous view to the end of the list
                //    c.wl_list_remove(&current_view.*.link);
                //    c.wl_list_insert(server.*.views.prev, &current_view.*.link);
                //}
            },
            else => return false,
        }
        return true;
    }

};
