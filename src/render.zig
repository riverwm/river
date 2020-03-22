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
