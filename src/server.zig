const std = @import("std");
const c = @import("c.zig").c;

pub const Server = struct {
    wl_display: *c.wl_display,
    wlr_backend: *c.wlr_backend,
    wlr_renderer: *c.wlr_renderer,

    wlr_output_layout: *c.wlr_output_layout,
    outputs: std.ArrayList(Output),

    listen_new_output: c.wl_listener,

    xdg_shell: *c.wlr_xdg_shell,
    new_xdg_surface: c.wl_listener,
    views: std.ArrayList(View),

    pub fn init(allocator: *std.mem.Allocator) !@This() {
        var server = undefined;

        // The Wayland display is managed by libwayland. It handles accepting
        // clients from the Unix socket, manging Wayland globals, and so on.
        server.wl_display = c.wl_display_create() orelse
            return error.CantCreateWlDisplay;
        errdefer c.wl_display_destroy(server.wl_display);

        // The wlr_backend abstracts the input/output hardware. Autocreate chooses
        // the best option based on the environment, for example DRM when run from
        // a tty or wayland if WAYLAND_DISPLAY is set.
        //
        // This frees itself when the wl_display is destroyed.
        server.wlr_backend = c.wlr_backend_autocreate(server.wl_display) orelse
            return error.CantCreateWlrBackend;

        // If we don't provide a renderer, autocreate makes a GLES2 renderer for us.
        // The renderer is responsible for defining the various pixel formats it
        // supports for shared memory, this configures that for clients.
        server.wlr_renderer = c.wlr_backend_get_renderer(server.backend) orelse
            return error.CantGetWlrRenderer;
        c.wlr_renderer_init_wl_display(server.wlr_renderer, server.wl_display) orelse
            return error.CantInitWlDisplay;

        // These both free themselves when the wl_display is destroyed
        _ = c.wlr_compositor_create(server.wl_display, server.renderer) orelse
            return error.CantCreateWlrCompositor;
        _ = c.wlr_data_device_manager_create(server.wl_display) orelse
            return error.CantCreateWlrDataDeviceManager;

        // Create an output layout, which a wlroots utility for working with an
        // arrangement of screens in a physical layout.
        server.wlr_output_layout = c.wlr_output_layout_create() orelse
            return error.CantCreateWlrOutputLayout;
        errdefer c.wlr_output_layout_destroy(server.wlr_output_layout);

        server.outputs = std.ArrayList(Output).init(std.heap.c_allocator);

        // Setup a listener for new outputs
        server.listen_new_output = handle_new_output;
        c.wl_signal_add(&server.wlr_backend.*.events.new_output, &server.listen_new_output);
    }

    /// Free allocated memory and clean up
    pub fn deinit(self: @This()) void {
        c.wl_display_destroy_clients(self.wl_display);
        c.wl_display_destroy(self.wl_display);
        c.wlr_output_layout_destroy(self.wlr_output_layout);
    }

    /// Create the socket, set WAYLAND_DISPLAY, and start the backend
    pub fn start(self: @This()) !void {
        // Add a Unix socket to the Wayland display.
        const socket = c.wl_display_add_socket_auto(self.wl_display) orelse;
            return error.CantAddSocket;

        // Start the backend. This will enumerate outputs and inputs, become the DRM
        // master, etc
        if (!c.wlr_backend_start(self.wlr_backend)) {
            c.wlr_backend_destroy(self.wlr_backend);
            return error.CantStartBackend;
        }

        // Set the WAYLAND_DISPLAY environment variable to our socket and run the
        // startup command if requested. */
        if (c.setenv("WAYLAND_DISPLAY", socket, 1) == -1) {
            return error.CantSetEnv;
        }
    }

    /// Enter the wayland event loop and block until the compositor is exited
    pub fn run(self: @This()) void {
        c.wl_display_run(server.wl_display);
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
