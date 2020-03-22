const std = @import("std");
const c = @import("c.zig").c;
const man_c = @import("c.zig").manual;

const ZagError = error{
    InitError,
    CantAddSocket,
    CantStartBackend,
    CantSetEnv,
};

pub fn main() !void {
    std.debug.warn("Starting up.\n", .{});

    c.wlr_log_init(c.enum_wlr_log_importance.WLR_DEBUG, null);

    var server: Server = undefined;

    // Creates an output layout, which a wlroots utility for working with an
    // arrangement of screens in a physical layout.
    server.output_layout = c.wlr_output_layout_create();

    server.outputs = std.ArrayList(Output).init(std.heap.c_allocator);

    // Configure a listener to be notified when new outputs are available on the
    // backend.
    server.new_output.notify = server_new_output;
    c.wl_signal_add(&server.backend.*.events.new_output, &server.new_output);

    // Set up our list of views and the xdg-shell. The xdg-shell is a Wayland
    // protocol which is used for application windows.
    // https://drewdevault.com/2018/07/29/Wayland-shells.html
    server.views = std.ArrayList(View).init(std.heap.c_allocator);
    server.xdg_shell = c.wlr_xdg_shell_create(server.wl_display);
    server.new_xdg_surface.notify = server_new_xdg_surface;
    c.wl_signal_add(&server.xdg_shell.*.events.new_surface, &server.new_xdg_surface);

    // Add a Unix socket to the Wayland display.
    const socket = c.wl_display_add_socket_auto(server.wl_display);
    if (socket == null) {
        c.zag_wlr_backend_destroy(server.backend);
        return ZagError.CantAddSocket;
    }

    // Start the backend. This will enumerate outputs and inputs, become the DRM
    // master, etc
    if (!c.zag_wlr_backend_start(server.backend)) {
        c.zag_wlr_backend_destroy(server.backend);
        c.wl_display_destroy(server.wl_display);
        return ZagError.CantStartBackend;
    }

    // Set the WAYLAND_DISPLAY environment variable to our socket and run the
    // startup command if requested. */
    if (c.setenv("WAYLAND_DISPLAY", socket, 1) == -1) {
        return ZagError.CantSetEnv;
    }

    const argv = [_][]const u8{ "/bin/sh", "-c", "WAYLAND_DEBUG=1 alacritty" };
    var child = try std.ChildProcess.init(&argv, std.heap.c_allocator);
    try std.ChildProcess.spawn(child);

    // Run the Wayland event loop. This does not return until you exit the
    // compositor. Starting the backend rigged up all of the necessary event
    // loop configuration to listen to libinput events, DRM events, generate
    // frame events at the refresh rate, and so on.
    //c.wlr_log(WLR_INFO, "Running Wayland compositor on WAYLAND_DISPLAY=%s", socket);
    c.wl_display_run(server.wl_display);

    // Once wl_display_run returns, we shut down the server.
    c.wl_display_destroy_clients(server.wl_display);
    c.wl_display_destroy(server.wl_display);
}
