const std = @import("std");
const c = @import("c.zig").c;

const Output = @import("output.zig").Output;
const Seat = @import("seat.zig").Seat;
const View = @import("view.zig").View;

pub const Server = struct {
    wl_display: *c.wl_display,
    wlr_backend: *c.wlr_backend,
    wlr_renderer: *c.wlr_renderer,

    wlr_output_layout: *c.wlr_output_layout,
    outputs: std.ArrayList(Output),

    listen_new_output: c.wl_listener,

    wlr_xdg_shell: *c.wlr_xdg_shell,
    listen_new_xdg_surface: c.wl_listener,

    // Must stay ordered bottom to top
    views: std.ArrayList(View),

    seat: Seat,

    pub fn init(allocator: *std.mem.Allocator) !@This() {
        var server: @This() = undefined;

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
        server.wlr_backend = c.zag_wlr_backend_autocreate(server.wl_display) orelse
            return error.CantCreateWlrBackend;

        // If we don't provide a renderer, autocreate makes a GLES2 renderer for us.
        // The renderer is responsible for defining the various pixel formats it
        // supports for shared memory, this configures that for clients.
        server.wlr_renderer = c.zag_wlr_backend_get_renderer(server.wlr_backend) orelse
            return error.CantGetWlrRenderer;
        // TODO: Handle failure after https://github.com/swaywm/wlroots/pull/2080
        c.wlr_renderer_init_wl_display(server.wlr_renderer, server.wl_display);// orelse
        //    return error.CantInitWlDisplay;

        // These both free themselves when the wl_display is destroyed
        _ = c.wlr_compositor_create(server.wl_display, server.wlr_renderer) orelse
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
        server.listen_new_output.notify = handle_new_output;
        c.wl_signal_add(&server.wlr_backend.*.events.new_output, &server.listen_new_output);

        // Set up our list of views and the xdg-shell. The xdg-shell is a Wayland
        // protocol which is used for application windows.
        // https://drewdevault.com/2018/07/29/Wayland-shells.html
        server.views = std.ArrayList(View).init(std.heap.c_allocator);
        server.wlr_xdg_shell = c.wlr_xdg_shell_create(server.wl_display) orelse
            return error.CantCreateWlrXdgShell;
        server.listen_new_xdg_surface.notify = handle_new_xdg_surface;
        c.wl_signal_add(&server.wlr_xdg_shell.*.events.new_surface, &server.listen_new_xdg_surface);

        server.seat = try Seat.init(&server, std.heap.c_allocator);

        return server;
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
        const socket = c.wl_display_add_socket_auto(self.wl_display) orelse
            return error.CantAddSocket;

        // Start the backend. This will enumerate outputs and inputs, become the DRM
        // master, etc
        if (!c.zag_wlr_backend_start(self.wlr_backend)) {
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
        c.wl_display_run(self.wl_display);
    }

    pub fn handle_keybinding(self: *@This(), sym: c.xkb_keysym_t) bool {
        // Here we handle compositor keybindings. This is when the compositor is
        // processing keys, rather than passing them on to the client for its own
        // processing.
        //
        // This function assumes the proper modifier is held down.
        switch (sym) {
            c.XKB_KEY_Escape => c.wl_display_terminate(self.wl_display),
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

    fn handle_new_output(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
        var server = @fieldParentPtr(Server, "listen_new_output", listener);
        var wlr_output = @ptrCast(*c.wlr_output, @alignCast(@alignOf(*c.wlr_output), data));

        // TODO: Handle failure
        server.outputs.append(Output.init(server, wlr_output) catch unreachable) catch unreachable;
    }

    fn handle_new_xdg_surface(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is raised when wlr_xdg_shell receives a new xdg surface from a
        // client, either a toplevel (application window) or popup.
        var server = @fieldParentPtr(Server, "listen_new_xdg_surface", listener);
        var wlr_xdg_surface = @ptrCast(*c.wlr_xdg_surface, @alignCast(@alignOf(*c.wlr_xdg_surface), data));

        if (wlr_xdg_surface.role != c.enum_wlr_xdg_surface_role.WLR_XDG_SURFACE_ROLE_TOPLEVEL) {
            return;
        }

        // Init a View to handle this surface
        server.*.views.append(View.init(server, wlr_xdg_surface)) catch unreachable;
    }

    /// Finds the top most view under the output layout coordinates lx, ly
    /// returns the view if found, and a pointer to the wlr_surface as well as the surface coordinates
    pub fn desktop_view_at(self: *@This(), lx: f64, ly: f64, surface: *?*c.wlr_surface, sx: *f64, sy: *f64) ?*View {
        for (self.views.span()) |*view| {
            if (view.is_at(lx, ly, surface, sx, sy)) {
                return view;
            }
        }
        return null;
    }
};
