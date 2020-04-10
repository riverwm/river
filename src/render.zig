const std = @import("std");
const c = @import("c.zig");

const LayerSurface = @import("layer_surface.zig").LayerSurface;
const Output = @import("output.zig").Output;
const Server = @import("server.zig").Server;
const View = @import("view.zig").View;
const ViewStack = @import("view_stack.zig").ViewStack;

pub fn renderOutput(output: *Output) void {
    const renderer = output.root.server.wlr_renderer;

    var now: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &now);

    // wlr_output_attach_render makes the OpenGL context current.
    if (!c.wlr_output_attach_render(output.wlr_output, null)) {
        return;
    }
    // The "effective" resolution can change if you rotate your outputs.
    var width: c_int = undefined;
    var height: c_int = undefined;
    c.wlr_output_effective_resolution(output.wlr_output, &width, &height);
    // Begin the renderer (calls glViewport and some other GL sanity checks)
    c.wlr_renderer_begin(renderer, width, height);

    const color = [_]f32{ 0.0, 0.16862745, 0.21176471, 1.0 };
    c.wlr_renderer_clear(renderer, &color);

    // The view has a position in layout coordinates. If you have two displays,
    // one next to the other, both 1080p, a view on the rightmost display might
    // have layout coordinates of 2000,100. We need to translate that to
    // output-local coordinates, or (2000 - 1920).
    var ox: f64 = 0.0;
    var oy: f64 = 0.0;
    c.wlr_output_layout_output_coords(
        output.root.wlr_output_layout,
        output.wlr_output,
        &ox,
        &oy,
    );

    renderLayer(output.*, output.layers[c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND], &now, ox, oy);
    renderLayer(output.*, output.layers[c.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM], &now, ox, oy);

    // The first view in the list is "on top" so iterate in reverse.
    var it = ViewStack.reverseIterator(
        output.root.views.last,
        output.root.current_focused_tags,
    );
    while (it.next()) |view| {
        // This check prevents a race condition when a frame is requested
        // between mapping of a view and the first configure being handled.
        if (view.current_box.width == 0 or view.current_box.height == 0) {
            continue;
        }
        renderView(output.*, view, &now, ox, oy);
        renderBorders(output.*, view, &now, ox, oy);
    }

    renderLayer(output.*, output.layers[c.ZWLR_LAYER_SHELL_V1_LAYER_TOP], &now, ox, oy);
    renderLayer(output.*, output.layers[c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY], &now, ox, oy);

    // Hardware cursors are rendered by the GPU on a separate plane, and can be
    // moved around without re-rendering what's beneath them - which is more
    // efficient. However, not all hardware supports hardware cursors. For this
    // reason, wlroots provides a software fallback, which we ask it to render
    // here. wlr_cursor handles configuring hardware vs software cursors for you,
    // and this function is a no-op when hardware cursors are in use.
    c.wlr_output_render_software_cursors(output.wlr_output, null);

    // Conclude rendering and swap the buffers, showing the final frame
    // on-screen.
    c.wlr_renderer_end(renderer);
    // TODO: handle failure
    _ = c.wlr_output_commit(output.wlr_output);
}

const LayerSurfaceRenderData = struct {
    output: *c.wlr_output,
    renderer: *c.wlr_renderer,
    layer_surface: *LayerSurface,
    when: *c.struct_timespec,
    ox: f64,
    oy: f64,
};

/// Render all surfaces on the passed layer
fn renderLayer(output: Output, layer: std.TailQueue(LayerSurface), now: *c.struct_timespec, ox: f64, oy: f64) void {
    var it = layer.first;
    while (it) |node| : (it = node.next) {
        const layer_surface = &node.data;
        var rdata = LayerSurfaceRenderData{
            .output = output.wlr_output,
            .renderer = output.root.server.wlr_renderer,
            .layer_surface = layer_surface,
            .when = now,
            .ox = ox,
            .oy = oy,
        };
        c.wlr_layer_surface_v1_for_each_surface(
            layer_surface.wlr_layer_surface,
            renderLayerSurface,
            &rdata,
        );
    }
}

/// This function is called for every layer surface and popup that needs to be rendered.
/// TODO: refactor this to reduce code duplication
fn renderLayerSurface(_surface: ?*c.wlr_surface, sx: c_int, sy: c_int, data: ?*c_void) callconv(.C) void {
    // wlroots says this will never be null
    const surface = _surface.?;
    // This function is called for every surface that needs to be rendered.
    const rdata = @ptrCast(*LayerSurfaceRenderData, @alignCast(@alignOf(LayerSurfaceRenderData), data));
    const layer_surface = rdata.layer_surface;
    const output = rdata.output;

    // We first obtain a wlr_texture, which is a GPU resource. wlroots
    // automatically handles negotiating these with the client. The underlying
    // resource could be an opaque handle passed from the client, or the client
    // could have sent a pixel buffer which we copied to the GPU, or a few other
    // means. You don't have to worry about this, wlroots takes care of it.
    const texture = c.wlr_surface_get_texture(surface);
    if (texture == null) {
        return;
    }

    var box = c.wlr_box{
        .x = @floatToInt(c_int, rdata.ox) + layer_surface.box.x + sx,
        .y = @floatToInt(c_int, rdata.oy) + layer_surface.box.y + sy,
        .width = surface.current.width,
        .height = surface.current.height,
    };

    // Scale the box to the output's current scaling factor
    scaleBox(&box, output.scale);

    // wlr_matrix_project_box is a helper which takes a box with a desired
    // x, y coordinates, width and height, and an output geometry, then
    // prepares an orthographic projection and multiplies the necessary
    // transforms to produce a model-view-projection matrix.
    var matrix: [9]f32 = undefined;
    const transform = c.wlr_output_transform_invert(surface.current.transform);
    c.wlr_matrix_project_box(&matrix, &box, transform, 0.0, &output.transform_matrix);

    // This takes our matrix, the texture, and an alpha, and performs the actual
    // rendering on the GPU.
    _ = c.wlr_render_texture_with_matrix(rdata.renderer, texture, &matrix, 1.0);

    // This lets the client know that we've displayed that frame and it can
    // prepare another one now if it likes.
    c.wlr_surface_send_frame_done(surface, rdata.when);
}

const ViewRenderData = struct {
    output: *c.wlr_output,
    renderer: *c.wlr_renderer,
    view: *View,
    when: *c.struct_timespec,
    ox: f64,
    oy: f64,
};

fn renderView(output: Output, view: *View, now: *c.struct_timespec, ox: f64, oy: f64) void {
    // If we have a stashed buffer, we are in the middle of a transaction
    // and need to render that buffer until the transaction is complete.
    if (view.stashed_buffer) |buffer| {
        const border_width = view.root.server.config.border_width;
        const view_padding = view.root.server.config.view_padding;
        var box = c.wlr_box{
            .x = view.current_box.x + @intCast(i32, border_width + view_padding),
            .y = view.current_box.y + @intCast(i32, border_width + view_padding),
            .width = @intCast(c_int, view.current_box.width - border_width * 2 - view_padding * 2),
            .height = @intCast(c_int, view.current_box.height - border_width * 2 - view_padding * 2),
        };

        // Scale the box to the output's current scaling factor
        scaleBox(&box, output.wlr_output.scale);

        var matrix: [9]f32 = undefined;
        c.wlr_matrix_project_box(
            &matrix,
            &box,
            c.enum_wl_output_transform.WL_OUTPUT_TRANSFORM_NORMAL,
            0.0,
            &output.wlr_output.transform_matrix,
        );

        // This takes our matrix, the texture, and an alpha, and performs the actual
        // rendering on the GPU.
        _ = c.wlr_render_texture_with_matrix(
            output.root.server.wlr_renderer,
            buffer.texture,
            &matrix,
            1.0,
        );
    } else {
        // Since there is no stashed buffer, we are not in the middle of
        // a transaction and may simply render each toplevel surface.
        var rdata = ViewRenderData{
            .output = output.wlr_output,
            .view = view,
            .renderer = output.root.server.wlr_renderer,
            .when = now,
            .ox = ox,
            .oy = oy,
        };

        // This calls our render_surface function for each surface among the
        // xdg_surface's toplevel and popups.
        c.wlr_xdg_surface_for_each_surface(view.wlr_xdg_surface, renderSurface, &rdata);
    }
}

/// This function is called for every toplevel and popup surface that needs to be rendered.
fn renderSurface(_surface: ?*c.wlr_surface, sx: c_int, sy: c_int, data: ?*c_void) callconv(.C) void {
    // wlroots says this will never be null
    const surface = _surface.?;
    const rdata = @ptrCast(*ViewRenderData, @alignCast(@alignOf(ViewRenderData), data));
    const view = rdata.view;
    const output = rdata.output;

    // We first obtain a wlr_texture, which is a GPU resource. wlroots
    // automatically handles negotiating these with the client. The underlying
    // resource could be an opaque handle passed from the client, or the client
    // could have sent a pixel buffer which we copied to the GPU, or a few other
    // means. You don't have to worry about this, wlroots takes care of it.
    const texture = c.wlr_surface_get_texture(surface);
    if (texture == null) {
        return;
    }

    const border_width = view.root.server.config.border_width;
    const view_padding = view.root.server.config.view_padding;
    var box = c.wlr_box{
        .x = @floatToInt(c_int, rdata.ox) + view.current_box.x + sx +
            @intCast(c_int, border_width + view_padding),
        .y = @floatToInt(c_int, rdata.oy) + view.current_box.y + sy +
            @intCast(c_int, border_width + view_padding),
        .width = surface.current.width,
        .height = surface.current.height,
    };

    // Scale the box to the output's current scaling factor
    scaleBox(&box, output.scale);

    // wlr_matrix_project_box is a helper which takes a box with a desired
    // x, y coordinates, width and height, and an output geometry, then
    // prepares an orthographic projection and multiplies the necessary
    // transforms to produce a model-view-projection matrix.
    var matrix: [9]f32 = undefined;
    const transform = c.wlr_output_transform_invert(surface.current.transform);
    c.wlr_matrix_project_box(&matrix, &box, transform, 0.0, &output.transform_matrix);

    // This takes our matrix, the texture, and an alpha, and performs the actual
    // rendering on the GPU.
    _ = c.wlr_render_texture_with_matrix(rdata.renderer, texture, &matrix, 1.0);

    // This lets the client know that we've displayed that frame and it can
    // prepare another one now if it likes.
    c.wlr_surface_send_frame_done(surface, rdata.when);
}

fn renderBorders(output: Output, view: *View, now: *c.struct_timespec, ox: f64, oy: f64) void {
    var border: c.wlr_box = undefined;
    const color = if (output.root.focused_view == view)
        [_]f32{ 0.57647059, 0.63137255, 0.63137255, 1.0 } // Solarized base1
    else
        [_]f32{ 0.34509804, 0.43137255, 0.45882353, 1.0 }; // Solarized base01
    const border_width = output.root.server.config.border_width;
    const view_padding = output.root.server.config.view_padding;

    // left border
    border.x = @floatToInt(c_int, ox) + view.current_box.x + @intCast(c_int, view_padding);
    border.y = @floatToInt(c_int, oy) + view.current_box.y + @intCast(c_int, view_padding);
    border.width = @intCast(c_int, border_width);
    border.height = @intCast(c_int, view.current_box.height - view_padding * 2);
    scaleBox(&border, output.wlr_output.scale);
    c.wlr_render_rect(
        output.root.server.wlr_renderer,
        &border,
        &color,
        &output.wlr_output.transform_matrix,
    );

    // right border
    border.x = @floatToInt(c_int, ox) + view.current_box.x +
        @intCast(c_int, view.current_box.width - border_width - view_padding);
    border.y = @floatToInt(c_int, oy) + view.current_box.y + @intCast(c_int, view_padding);
    border.width = @intCast(c_int, border_width);
    border.height = @intCast(c_int, view.current_box.height - view_padding * 2);
    scaleBox(&border, output.wlr_output.scale);
    c.wlr_render_rect(
        output.root.server.wlr_renderer,
        &border,
        &color,
        &output.wlr_output.transform_matrix,
    );

    // top border
    border.x = @floatToInt(c_int, ox) + view.current_box.x +
        @intCast(c_int, border_width + view_padding);
    border.y = @floatToInt(c_int, oy) + view.current_box.y +
        @intCast(c_int, view_padding);
    border.width = @intCast(c_int, view.current_box.width -
        border_width * 2 - view_padding * 2);
    border.height = @intCast(c_int, border_width);
    scaleBox(&border, output.wlr_output.scale);
    c.wlr_render_rect(
        output.root.server.wlr_renderer,
        &border,
        &color,
        &output.wlr_output.transform_matrix,
    );

    // bottom border
    border.x = @floatToInt(c_int, ox) + view.current_box.x +
        @intCast(c_int, border_width + view_padding);
    border.y = @floatToInt(c_int, oy) + view.current_box.y +
        @intCast(c_int, view.current_box.height - border_width - view_padding);
    border.width = @intCast(c_int, view.current_box.width -
        border_width * 2 - view_padding * 2);
    border.height = @intCast(c_int, border_width);
    scaleBox(&border, output.wlr_output.scale);
    c.wlr_render_rect(
        output.root.server.wlr_renderer,
        &border,
        &color,
        &output.wlr_output.transform_matrix,
    );
}

/// Scale a wlr_box, taking the possibility of fractional scaling into account.
fn scaleBox(box: *c.wlr_box, scale: f64) void {
    box.x = @floatToInt(c_int, @round(@intToFloat(f64, box.x) * scale));
    box.y = @floatToInt(c_int, @round(@intToFloat(f64, box.y) * scale));
    box.width = scaleLength(box.width, box.x, scale);
    box.height = scaleLength(box.height, box.x, scale);
}

/// Scales a width/height.
///
/// This might seem overly complex, but it needs to work for fractional scaling.
fn scaleLength(length: c_int, offset: c_int, scale: f64) c_int {
    return @floatToInt(c_int, @round(@intToFloat(f64, offset + length) * scale) -
        @round(@intToFloat(f64, offset) * scale));
}
