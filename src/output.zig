const std = @import("std");
const c = @import("c.zig").c;

const Output = struct {
    server: *Server,
    wlr_output: *c.wlr_output,
    listen_frame: c.wl_listener,

    pub fn init(server: *Server, wlr_output: *c.wlr_output) !@This() {
        // Some backends don't have modes. DRM+KMS does, and we need to set a mode
        // before we can use the output. The mode is a tuple of (width, height,
        // refresh rate), and each monitor supports only a specific set of modes. We
        // just pick the monitor's preferred mode, a more sophisticated compositor
        // would let the user configure it.

        // if not empty
        if (c.wl_list_empty(&wlr_output.*.modes) == 0) {
            const mode = c.wlr_output_preferred_mode(wlr_output);
            c.wlr_output_set_mode(wlr_output, mode);
            c.wlr_output_enable(wlr_output, true);
            if (!c.wlr_output_commit(wlr_output)) {
                return error.CantCommitWlrOutputMode;
            }
        }

        var output = @This(){
            .server = server,
            .wlr_output = wlr_output,
            .listen_frame = c.wl_listener{
                .link = undefined,
                .notify = handle_frame,
            },
        };

        // Sets up a listener for the frame notify event.
        c.wl_signal_add(&wlr_output.*.events.frame, &output.*.listen_frame);

        // Add the new output to the layout. The add_auto function arranges outputs
        // from left-to-right in the order they appear. A more sophisticated
        // compositor would let the user configure the arrangement of outputs in the
        // layout.
        c.wlr_output_layout_add_auto(server.output_layout, wlr_output);

        // Creating the global adds a wl_output global to the display, which Wayland
        // clients can see to find out information about the output (such as
        // DPI, scale factor, manufacturer, etc).
        c.wlr_output_create_global(wlr_output);

        return output;
    }

    fn handle_frame(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
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
        for (output.*.server.views.span()) |*view| {
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
};
