const std = @import("std");

const c = @cImport({
    @cDefine("WLR_USE_UNSTABLE", {});
    @cInclude("wayland-server-core.h");
    @cInclude("wlr/render/wlr_renderer.h");
    @cInclude("wlr/types/wlr_cursor.h");
    @cInclude("wlr/types/wlr_compositor.h");
    @cInclude("wlr/types/wlr_data_device.h");
    @cInclude("wlr/types/wlr_input_device.h");
    @cInclude("wlr/types/wlr_keyboard.h");
    @cInclude("wlr/types/wlr_matrix.h");
    @cInclude("wlr/types/wlr_output.h");
    @cInclude("wlr/types/wlr_output_layout.h");
    @cInclude("wlr/types/wlr_pointer.h");
    @cInclude("wlr/types/wlr_seat.h");
    @cInclude("wlr/types/wlr_xcursor_manager.h");
    @cInclude("wlr/types/wlr_xdg_shell.h");
    @cInclude("wlr/util/log.h");
    @cInclude("xkbcommon/xkbcommon.h");
});

const CursorMode = enum {
    Passthrough,
    Move,
    Resize,
};

fn create_list() c.wl_list {
    return c.wl_list{
        .prev = null,
        .next = null,
    };
}

fn create_listener() c.wl_listener {
    return c.wl_listener{
        .link = create_list(),
        .notify = null,
    };
}

const RenderData = struct {
    output: *c.wlr_output,
    renderer: *c.wlr_renderer,
    view: *View,
    when: *std.os.timespec,
};

fn output_frame(listener: *c.wl_listener, data: *c_void) void {
    // This function is called every time an output is ready to display a frame,
    // generally at the output's refresh rate (e.g. 60Hz). */
    var output = @fieldParentPtr(Output, "frame", listener);
    var renderer = output.*.server.*.renderer;

    var now = undefined;
    std.os.linux.clock_gettime(std.os.CLOCK_MONOTONIC, &now);

    // wlr_output_attach_render makes the OpenGL context current.
    if (!c.wlr_output_attach_render(output.*.wlr_output, null)) {
        return;
    }
    // The "effective" resolution can change if you rotate your outputs.
    var width = undefined;
    var height = undefined;
    c.wlr_output_effective_resolution(output.*.wlr_output, &width, &height);
    // Begin the renderer (calls glViewport and some other GL sanity checks)
    c.wlr_renderer_begin(renderer, width, height);

    const color = [_]f32{ 0.3, 0.3, 0.3, 1.0 };
    c.wlr_renderer_clear(renderer, color);

    // Each subsequent window we render is rendered on top of the last. Because
    //  our view list is ordered front-to-back, we iterate over it backwards.
    // wl_list_for_each_reverse(view, &output.*.server.*.views, link) {

    var view = @fieldParentPtr(View, "link", &output.*.server.*.views.*.prev);

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
        view = @fieldParentPtr(View, "link", view.*.link.*.prev);
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
    c.wlr_output_commit(output.*.wlr_output);
}

fn server_new_output(listener: *c.wl_listener, data: *c_void) void {
    var server = @fieldParentPtr(Server, "new_output", listener);
    var wlr_output = @ptrCast(c.wlr_output, data);

    // Some backends don't have modes. DRM+KMS does, and we need to set a mode
    // before we can use the output. The mode is a tuple of (width, height,
    // refresh rate), and each monitor supports only a specific set of modes. We
    // just pick the monitor's preferred mode, a more sophisticated compositor
    // would let the user configure it.
    if (!c.wl_list_empty(&wlr_output.*.modes)) {
        var mode = wlr_output_preferred_mode(wlr_output);
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

const Server = struct {
    wl_display: *c.wl_display,
    backend: *c.wlr_backend,
    renderer: *c.wlr_renderer,

    xdg_shell: ?*c.wlr_xdg_shell,
    new_xdg_surface: c.wl_listener,
    views: c.wl_list,

    cursor: ?*c.wlr_cursor,
    cursor_mgr: ?*c.wlr_xcursor_manager,
    cursor_motion: c.wl_listener,
    cursor_motion_absolute: c.wl_listener,
    cursor_button: c.wl_listener,
    cursor_axis: c.wl_listener,
    cursor_frame: c.wl_listener,

    seat: ?*c.wlr_seat,
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

    fn create() Server {
        const wl_display = c.wl_display_create();
        const backend = c.wlr_backend_autocreate(wl_display, null);
        const renderer = c.wlr_backend_get_renderer(server.backend);
        wlr_renderer_init_wl_display(renderer, wl_display);

        wlr_compositor_create(wl_display, renderer);
        wlr_data_device_manager_create(wl_display);

        const output_layout = wlr_output_layout_create();
        var outputs = create_list();
        wl_list_init(&outputs);

        new_output = create_listener();
        server.new_output.notify = server_new_output;
        wl_signal_add(&server.backend.*.events.new_output, &server.new_output);

        return Server{
            .wl_display = wl_display,
            .backend = backend,
            .renderer = null,

            .xdg_shell = null,
            .new_xdg_surface = create_listener(),
            .views = create_list(),

            .cursor = null,
            .cursor_mgr = null,
            .cursor_motion = create_listener(),
            .cursor_motion_absolute = create_listener(),
            .cursor_button = create_listener(),
            .cursor_axis = create_listener(),
            .cursor_frame = create_listener(),

            .seat = null,
            .new_input = create_listener(),
            .request_cursor = create_listener(),
            .keyboards = create_list(),
            .cursor_mode = CursorMode.Passthrough,
            .grabbed_view = null,
            .grab_x = 0.0,
            .grab_y = 0.0,
            .grab_width = 0,
            .grab_height = 0,
            .resize_edges = 0,

            .output_layout = null,
            .outputs = c.wl_list{ .prev = null, .next = null },
            .new_output = create_listener(),
        };
    }
};

const Output = struct {
    link: c.wl_list,
    server: *c.tinywl_server,
    xdg_surface: ?*c.wlr_xdg_surface,
    map: c.wl_listener,
    unmap: c.wl_listener,
    destroy: c.wl_listener,
    request_move: c.wl_listener,
    request_resize: c.wl_listener,
    mapped: bool,
    x: c_int,
    y: c_int,
};

const View = struct {
    link: c.wl_list,
    server: *Server,
    xdg_surface: ?*c.wlr_xdg_surface,
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
    device: ?*c.wlr_input_device,

    modifiers: c.wl_listener,
    key: c.wl_listener,
};

pub fn main() !void {
    std.debug.warn("Starting up.\n", .{});

    c.wlr_log_init(c.enum_wlr_log_importance.WLR_DEBUG, null);

    var server = Server.create();
}
