const std = @import("std");
const c = @import("c.zig").c;
const man_c = @import("c.zig").manual;

const Server = struct {
    wl_display: *c.wl_display,
    backend: *c.wlr_backend,
    renderer: *c.wlr_renderer,

    xdg_shell: *c.wlr_xdg_shell,
    new_xdg_surface: c.wl_listener,
    views: c.wl_list,

    cursor: ?*c.wlr_cursor,
    cursor_mgr: ?*c.wlr_xcursor_manager,
    cursor_motion: c.wl_listener,
    cursor_motion_absolute: c.wl_listener,
    cursor_button: c.wl_listener,
    cursor_axis: c.wl_listener,
    cursor_frame: c.wl_listener,

    seat: *c.wlr_seat,
    new_input: c.wl_listener,
    request_cursor: c.wl_listener,
    keyboards: c.wl_list,
    cursor_mode: CursorMode,
    grabbed_view: ?*View,
    grab_x: f64,
    grab_y: f64,
    grab_width: c_int,
    grab_height: c_int,
    resize_edges: u32,

    output_layout: ?*c.wlr_output_layout,
    outputs: c.wl_list,
    new_output: c.wl_listener,
};

const Output = struct {
    link: c.wl_list,
    server: *Server,
    wlr_output: *c.wlr_output,
    frame: c.wl_listener,
};

const View = struct {
    link: c.wl_list,
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

const Keyboard = struct {
    link: c.wl_list,
    server: *Server,
    device: *c.wlr_input_device,

    modifiers: c.wl_listener,
    key: c.wl_listener,
};

const CursorMode = enum {
    Passthrough,
    Move,
    Resize,
};

fn new_list() c.wl_list {
    return c.wl_list{
        .prev = null,
        .next = null,
    };
}

fn new_listener() c.wl_listener {
    return c.wl_listener{
        .link = new_list(),
        .notify = null,
    };
}

const RenderData = struct {
    output: *c.wlr_output,
    renderer: *c.wlr_renderer,
    view: *View,
    when: *c.struct_timespec,
};

fn render_surface(surface: [*c]c.wlr_surface, sx: c_int, sy: c_int, data: ?*c_void) callconv(.C) void {
    // This function is called for every surface that needs to be rendered.
    var rdata = @ptrCast(*RenderData, @alignCast(@alignOf(RenderData), data));
    var view = rdata.*.view;
    var output = rdata.*.output;

    // We first obtain a wlr_texture, which is a GPU resource. wlroots
    // automatically handles negotiating these with the client. The underlying
    // resource could be an opaque handle passed from the client, or the client
    // could have sent a pixel buffer which we copied to the GPU, or a few other
    // means. You don't have to worry about this, wlroots takes care of it.
    var texture = c.wlr_surface_get_texture(surface);
    if (texture == null) {
        return;
    }

    // The view has a position in layout coordinates. If you have two displays,
    // one next to the other, both 1080p, a view on the rightmost display might
    // have layout coordinates of 2000,100. We need to translate that to
    // output-local coordinates, or (2000 - 1920).
    var ox: f64 = 0.0;
    var oy: f64 = 0.0;
    c.wlr_output_layout_output_coords(view.*.server.*.output_layout, output, &ox, &oy);
    ox += @intToFloat(f64, view.*.x + sx);
    oy += @intToFloat(f64, view.*.y + sy);

    // We also have to apply the scale factor for HiDPI outputs. This is only
    // part of the puzzle, TinyWL does not fully support HiDPI.
    var box = c.wlr_box{
        .x = @floatToInt(c_int, ox * output.*.scale),
        .y = @floatToInt(c_int, oy * output.*.scale),
        .width = @floatToInt(c_int, @intToFloat(f32, surface.*.current.width) * output.*.scale),
        .height = @floatToInt(c_int, @intToFloat(f32, surface.*.current.height) * output.*.scale),
    };

    // Those familiar with OpenGL are also familiar with the role of matricies
    // in graphics programming. We need to prepare a matrix to render the view
    // with. wlr_matrix_project_box is a helper which takes a box with a desired
    // x, y coordinates, width and height, and an output geometry, then
    // prepares an orthographic projection and multiplies the necessary
    // transforms to produce a model-view-projection matrix.
    //
    // Naturally you can do this any way you like, for example to make a 3D
    // compositor.
    var matrix: [9]f32 = undefined;
    var transform = c.wlr_output_transform_invert(surface.*.current.transform);
    c.wlr_matrix_project_box(&matrix, &box, transform, 0.0, &output.*.transform_matrix);

    // This takes our matrix, the texture, and an alpha, and performs the actual
    // rendering on the GPU.
    _ = c.wlr_render_texture_with_matrix(rdata.*.renderer, texture, &matrix, 1.0);

    // This lets the client know that we've displayed that frame and it can
    // prepare another one now if it likes.
    c.wlr_surface_send_frame_done(surface, rdata.*.when);
}

fn output_frame(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This function is called every time an output is ready to display a frame,
    // generally at the output's refresh rate (e.g. 60Hz).
    var output = @fieldParentPtr(Output, "frame", listener);
    var renderer = output.*.server.*.renderer;

    var now: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &now);

    // wlr_output_attach_render makes the OpenGL context current.
    if (!c.wlr_output_attach_render(output.*.wlr_output, null)) {
        return;
    }
    // The "effective" resolution can change if you rotate your outputs.
    var width: c_int = undefined;
    var height: c_int = undefined;
    c.wlr_output_effective_resolution(output.*.wlr_output, &width, &height);
    // Begin the renderer (calls glViewport and some other GL sanity checks)
    c.wlr_renderer_begin(renderer, width, height);

    const color = [_]f32{ 0.3, 0.3, 0.3, 1.0 };
    c.wlr_renderer_clear(renderer, &color);

    // Each subsequent window we render is rendered on top of the last. Because
    //  our view list is ordered front-to-back, we iterate over it backwards.
    // wl_list_for_each_reverse(view, &output.*.server.*.views, link) {

    var view = @fieldParentPtr(View, "link", output.*.server.*.views.prev);

    while (&view.*.link != &output.*.server.*.views) {
        if (!view.*.mapped) {
            // An unmapped view should not be rendered.
            continue;
        }
        var rdata = RenderData{
            .output = output.*.wlr_output,
            .view = view,
            .renderer = renderer,
            .when = &now,
        };
        // This calls our render_surface function for each surface among the
        // xdg_surface's toplevel and popups.
        c.wlr_xdg_surface_for_each_surface(view.*.xdg_surface, render_surface, &rdata);

        // Move to next item in list
        view = @fieldParentPtr(View, "link", view.*.link.prev);
    }

    // Hardware cursors are rendered by the GPU on a separate plane, and can be
    // moved around without re-rendering what's beneath them - which is more
    // efficient. However, not all hardware supports hardware cursors. For this
    // reason, wlroots provides a software fallback, which we ask it to render
    // here. wlr_cursor handles configuring hardware vs software cursors for you,
    // and this function is a no-op when hardware cursors are in use.
    c.wlr_output_render_software_cursors(output.*.wlr_output, null);

    // Conclude rendering and swap the buffers, showing the final frame
    // on-screen.
    c.wlr_renderer_end(renderer);
    // TODO: handle failure
    _ = c.wlr_output_commit(output.*.wlr_output);
}

fn server_new_output(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
    var server = @fieldParentPtr(Server, "new_output", listener);
    var wlr_output = @ptrCast(*c.wlr_output, @alignCast(@alignOf(*c.wlr_output), data));

    // Some backends don't have modes. DRM+KMS does, and we need to set a mode
    // before we can use the output. The mode is a tuple of (width, height,
    // refresh rate), and each monitor supports only a specific set of modes. We
    // just pick the monitor's preferred mode, a more sophisticated compositor
    // would let the user configure it.

    // if not empty
    if (c.wl_list_empty(&wlr_output.*.modes) == 0) {
        var mode = c.wlr_output_preferred_mode(wlr_output);
        c.wlr_output_set_mode(wlr_output, mode);
        c.wlr_output_enable(wlr_output, true);
        if (!c.wlr_output_commit(wlr_output)) {
            return;
        }
    }

    // Allocates and configures our state for this output
    var output = std.heap.c_allocator.create(Output) catch unreachable;
    output.*.wlr_output = wlr_output;
    output.*.server = server;
    // Sets up a listener for the frame notify event.
    output.*.frame.notify = output_frame;
    c.wl_signal_add(&wlr_output.*.events.frame, &output.*.frame);
    c.wl_list_insert(&server.*.outputs, &output.*.link);

    // Adds this to the output layout. The add_auto function arranges outputs
    // from left-to-right in the order they appear. A more sophisticated
    // compositor would let the user configure the arrangement of outputs in the
    // layout.
    c.wlr_output_layout_add_auto(server.*.output_layout, wlr_output);

    // Creating the global adds a wl_output global to the display, which Wayland
    // clients can see to find out information about the output (such as
    // DPI, scale factor, manufacturer, etc).
    c.wlr_output_create_global(wlr_output);
}

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

    // Move the view to the front
    c.wl_list_remove(&view.*.link);
    c.wl_list_insert(&server.*.views, &view.*.link);

    // Activate the new surface
    _ = c.wlr_xdg_toplevel_set_activated(view.*.xdg_surface, true);

    // Tell the seat to have the keyboard enter this surface. wlroots will keep
    // track of this and automatically send key events to the appropriate
    // clients without additional work on your part.
    var keyboard = c.wlr_seat_get_keyboard(seat);
    c.wlr_seat_keyboard_notify_enter(seat, view.*.xdg_surface.*.surface, &keyboard.*.keycodes, keyboard.*.num_keycodes, &keyboard.*.modifiers);
}

fn xdg_surface_map(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
    // Called when the surface is mapped, or ready to display on-screen.
    var view = @fieldParentPtr(View, "map", listener);
    view.*.mapped = true;
    focus_view(view, view.*.xdg_surface.*.surface);
}

fn xdg_surface_unmap(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
    var view = @fieldParentPtr(View, "map", listener);
    view.*.mapped = false;
}

fn xdg_surface_destroy(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
    var view = @fieldParentPtr(View, "map", listener);
    c.wl_list_remove(&view.*.link);
    // TODO: free the memory
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
    var view = std.heap.c_allocator.create(View) catch unreachable;
    view.*.server = server;
    view.*.xdg_surface = xdg_surface;

    // Listen to the various events it can emit
    view.*.map.notify = xdg_surface_map;
    c.wl_signal_add(&xdg_surface.*.events.map, &view.*.map);

    view.*.unmap.notify = xdg_surface_unmap;
    c.wl_signal_add(&xdg_surface.*.events.unmap, &view.*.unmap);

    view.*.destroy.notify = xdg_surface_destroy;
    c.wl_signal_add(&xdg_surface.*.events.destroy, &view.*.destroy);

    var toplevel = xdg_surface.*.unnamed_161.toplevel;
    view.*.request_move.notify = xdg_toplevel_request_move;
    c.wl_signal_add(&toplevel.*.events.request_move, &view.*.request_move);

    view.*.request_resize.notify = xdg_toplevel_request_resize;
    c.wl_signal_add(&toplevel.*.events.request_resize, &view.*.request_resize);

    // Add it to the list of views.
    c.wl_list_insert(&server.*.views, &view.*.link);
}

fn keyboard_handle_modifiers(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is raised when a modifier key, such as shift or alt, is
    // pressed. We simply communicate this to the client. */
    var keyboard = @fieldParentPtr(Keyboard, "modifiers", listener);

    // A seat can only have one keyboard, but this is a limitation of the
    // Wayland protocol - not wlroots. We assign all connected keyboards to the
    // same seat. You can swap out the underlying wlr_keyboard like this and
    // wlr_seat handles this transparently.
    c.wlr_seat_set_keyboard(keyboard.*.server.*.seat, keyboard.*.device);

    // Send modifiers to the client.
    c.wlr_seat_keyboard_notify_modifiers(keyboard.*.server.*.seat, &keyboard.*.device.*.unnamed_132.keyboard.*.modifiers);
}

fn handle_keybinding(server: *Server, sym: c.xkb_keysym_t) bool {
    // Here we handle compositor keybindings. This is when the compositor is
    // processing keys, rather than passing them on to the client for its own
    // processing.
    //
    // This function assumes the proper modifier is held down.
    switch (sym) {
        c.XKB_KEY_Escape => c.wl_display_terminate(server.*.wl_display),
        c.XKB_KEY_F1 => {
            // Cycle to the next view
            if (c.wl_list_length(&server.*.views) > 1) {
                const current_view = @fieldParentPtr(View, "link", server.*.views.next);
                const next_view = @fieldParentPtr(View, "link", current_view.*.link.next);
                focus_view(next_view, next_view.*.xdg_surface.*.surface);
                // Move the previous view to the end of the list
                c.wl_list_remove(&current_view.*.link);
                c.wl_list_insert(server.*.views.prev, &current_view.*.link);
            }
        },
        else => return false,
    }
    return true;
}

fn keyboard_handle_key(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is raised when a key is pressed or released.
    const keyboard = @fieldParentPtr(Keyboard, "key", listener);
    const event = @ptrCast(*c.wlr_event_keyboard_key, @alignCast(@alignOf(*c.wlr_event_keyboard_key), data));

    const server = keyboard.*.server;
    const seat = server.*.seat;
    const keyboard_device = keyboard.*.device.*.unnamed_132.keyboard;

    // Translate libinput keycode -> xkbcommon
    const keycode = event.*.keycode + 8;
    // Get a list of keysyms based on the keymap for this keyboard
    var syms: [*c]c.xkb_keysym_t = undefined;
    const nsyms = c.xkb_state_key_get_syms(keyboard_device.*.xkb_state, keycode, &syms);

    var handled = false;
    const modifiers = c.wlr_keyboard_get_modifiers(keyboard_device);
    if (modifiers & @intCast(u32, c.WLR_MODIFIER_LOGO) != 0 and event.*.state == c.enum_wlr_key_state.WLR_KEY_PRESSED) {
        // If mod is held down and this button was _pressed_, we attempt to
        // process it as a compositor keybinding.
        var i: usize = 0;
        while (i < nsyms) {
            handled = handle_keybinding(server, syms[i]);
            if (handled) {
                break;
            }
            i += 1;
        }
    }

    if (!handled) {
        // Otherwise, we pass it along to the client.
        c.wlr_seat_set_keyboard(seat, keyboard.*.device);
        c.wlr_seat_keyboard_notify_key(seat, event.*.time_msec, event.*.keycode, @intCast(u32, @enumToInt(event.*.state)));
    }
}

fn server_new_keyboard(server: *Server, device: *c.wlr_input_device) void {
    var keyboard = std.heap.c_allocator.create(Keyboard) catch unreachable;
    keyboard.*.server = server;
    keyboard.*.device = device;

    // We need to prepare an XKB keymap and assign it to the keyboard. This
    // assumes the defaults (e.g. layout = "us").
    const rules = c.xkb_rule_names{
        .rules = null,
        .model = null,
        .layout = null,
        .variant = null,
        .options = null,
    };
    const context = c.xkb_context_new(c.enum_xkb_context_flags.XKB_CONTEXT_NO_FLAGS);
    defer c.xkb_context_unref(context);

    const keymap = man_c.xkb_map_new_from_names(context, &rules, c.enum_xkb_keymap_compile_flags.XKB_KEYMAP_COMPILE_NO_FLAGS);
    defer c.xkb_keymap_unref(keymap);

    var keyboard_device = device.*.unnamed_132.keyboard;
    c.wlr_keyboard_set_keymap(keyboard_device, keymap);
    c.wlr_keyboard_set_repeat_info(keyboard_device, 25, 600);

    // Setup listeners for keyboard events
    keyboard.*.modifiers.notify = keyboard_handle_modifiers;
    c.wl_signal_add(&keyboard_device.*.events.modifiers, &keyboard.*.modifiers);
    keyboard.*.key.notify = keyboard_handle_key;
    c.wl_signal_add(&keyboard_device.*.events.key, &keyboard.*.key);

    c.wlr_seat_set_keyboard(server.*.seat, device);

    // And add the keyboard to our list of keyboards
    c.wl_list_insert(&server.*.keyboards, &keyboard.*.link);
}

fn server_new_input(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is raised by the backend when a new input device becomes available.
    var server = @fieldParentPtr(Server, "new_input", listener);
    var device = @ptrCast(*c.wlr_input_device, @alignCast(@alignOf(*c.wlr_input_device), data));

    switch (device.*.type) {
        .WLR_INPUT_DEVICE_KEYBOARD => server_new_keyboard(server, device),
        else => {},
    }

    var caps: u32 = 0;
    // if list not empty
    if (c.wl_list_empty(&server.*.keyboards) == 0) {
        caps |= @intCast(u32, c.WL_SEAT_CAPABILITY_KEYBOARD);
    }
    c.wlr_seat_set_capabilities(server.*.seat, caps);
}

const ZagError = error{
    CantAddSocket,
    CantStartBackend,
    CantSetEnv,
};

pub fn main() !void {
    std.debug.warn("Starting up.\n", .{});

    c.wlr_log_init(c.enum_wlr_log_importance.WLR_DEBUG, null);

    var server: Server = undefined;
    // The Wayland display is managed by libwayland. It handles accepting
    // clients from the Unix socket, manging Wayland globals, and so on.
    server.wl_display = c.wl_display_create().?;

    // The backend is a wlroots feature which abstracts the underlying input and
    // output hardware. The autocreate option will choose the most suitable
    // backend based on the current environment, such as opening an X11 window
    // if an X11 server is running. The NULL argument here optionally allows you
    // to pass in a custom renderer if wlr_renderer doesn't meet your needs. The
    // backend uses the renderer, for example, to fall back to software cursors
    // if the backend does not support hardware cursors (some older GPUs
    // don't).
    server.backend = c.wlr_backend_autocreate(server.wl_display, null);

    // If we don't provide a renderer, autocreate makes a GLES2 renderer for us.
    // The renderer is responsible for defining the various pixel formats it
    // supports for shared memory, this configures that for clients.
    server.renderer = c.wlr_backend_get_renderer(server.backend);
    c.wlr_renderer_init_wl_display(server.renderer, server.wl_display);

    // This creates some hands-off wlroots interfaces. The compositor is
    // necessary for clients to allocate surfaces and the data device manager
    // handles the clipboard. Each of these wlroots interfaces has room for you
    // to dig your fingers in and play with their behavior if you want.
    _ = c.wlr_compositor_create(server.wl_display, server.renderer);
    _ = c.wlr_data_device_manager_create(server.wl_display);

    // Creates an output layout, which a wlroots utility for working with an
    // arrangement of screens in a physical layout.
    server.output_layout = c.wlr_output_layout_create();
    c.wl_list_init(&server.outputs);

    // Configure a listener to be notified when new outputs are available on the
    // backend.
    server.new_output.notify = server_new_output;
    c.wl_signal_add(&server.backend.*.events.new_output, &server.new_output);

    // Set up our list of views and the xdg-shell. The xdg-shell is a Wayland
    // protocol which is used for application windows.
    // https://drewdevault.com/2018/07/29/Wayland-shells.html
    c.wl_list_init(&server.views);
    server.xdg_shell = c.wlr_xdg_shell_create(server.wl_display);
    server.new_xdg_surface.notify = server_new_xdg_surface;
    c.wl_signal_add(&server.xdg_shell.*.events.new_surface, &server.new_xdg_surface);

    // Configures a seat, which is a single "seat" at which a user sits and
    // operates the computer. This conceptually includes up to one keyboard,
    // pointer, touch, and drawing tablet device. We also rig up a listener to
    // let us know when new input devices are available on the backend.
    c.wl_list_init(&server.keyboards);
    server.new_input.notify = server_new_input;
    c.wl_signal_add(&server.backend.*.events.new_input, &server.new_input);
    server.seat = c.wlr_seat_create(server.wl_display, "seat0");
    // server.request_cursor.notify = seat_request_cursor;
    // c.wl_signal_add(&server.seat.*.events.request_set_cursor, &server.request_cursor);

    // Add a Unix socket to the Wayland display.
    const socket = c.wl_display_add_socket_auto(server.wl_display);
    if (socket == null) {
        c.wlr_backend_destroy(server.backend);
        return ZagError.CantAddSocket;
    }

    // Start the backend. This will enumerate outputs and inputs, become the DRM
    // master, etc
    if (!c.wlr_backend_start(server.backend)) {
        c.wlr_backend_destroy(server.backend);
        c.wl_display_destroy(server.wl_display);
        return ZagError.CantStartBackend;
    }

    // Set the WAYLAND_DISPLAY environment variable to our socket and run the
    // startup command if requested. */
    if (c.setenv("WAYLAND_DISPLAY", socket, 1) == -1) {
        return ZagError.CantSetEnv;
    }

    const argv = [_][]const u8{ "/bin/sh", "-c", "alacritty" };
    var child = try std.ChildProcess.init(&argv, std.heap.c_allocator);
    try std.ChildProcess.spawn(child);
    //if (startup_cmd) {
    //if (std.os.linux.fork() == 0) {
    //    execl("/bin/sh", "/bin/sh", "-c", startup_cmd, (void *)NULL);
    //    std.os.linux.execve("/bin/sh",
    //}
    //}

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
