// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const build_options = @import("build_options");
const std = @import("std");

const c = @import("c.zig");
const util = @import("util.zig");

const Box = @import("Box.zig");
const LayerSurface = @import("LayerSurface.zig");
const Output = @import("Output.zig");
const Server = @import("Server.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;

const SurfaceRenderData = struct {
    output: *const Output,

    /// In output layout coordinates relative to the output
    output_x: i32,
    output_y: i32,

    when: *c.timespec,
};

pub fn renderOutput(output: *Output) void {
    const config = &output.root.server.config;
    const wlr_renderer = output.getRenderer();

    var now: c.timespec = undefined;
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
    c.wlr_renderer_begin(wlr_renderer, width, height);

    c.wlr_renderer_clear(wlr_renderer, &config.background_color);

    renderLayer(output.*, output.layers[c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND], &now);
    renderLayer(output.*, output.layers[c.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM], &now);

    // The first view in the list is "on top" so iterate in reverse.
    var it = ViewStack(View).reverseIterator(output.views.last, output.current_focused_tags);
    while (it.next()) |node| {
        const view = &node.view;

        // This check prevents a race condition when a frame is requested
        // between mapping of a view and the first configure being handled.
        if (view.current.box.width == 0 or view.current.box.height == 0) continue;

        // Focused views are rendered on top of normal views, skip them for now
        if (view.focused) continue;

        renderView(output.*, view, &now);
        renderBorders(output.*, view, &now);
    }

    // Render focused views
    it = ViewStack(View).reverseIterator(output.views.last, output.current_focused_tags);
    while (it.next()) |node| {
        const view = &node.view;

        // This check prevents a race condition when a frame is requested
        // between mapping of a view and the first configure being handled.
        if (view.current.box.width == 0 or view.current.box.height == 0) continue;

        // Skip unfocused views since we already rendered them
        if (!view.focused) continue;

        renderView(output.*, view, &now);
        renderBorders(output.*, view, &now);
    }

    // Render xwayland unmanged views
    if (build_options.xwayland) {
        renderXwaylandUnmanaged(output.*, &now);
    }

    renderLayer(output.*, output.layers[c.ZWLR_LAYER_SHELL_V1_LAYER_TOP], &now);
    renderLayer(output.*, output.layers[c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY], &now);

    // Hardware cursors are rendered by the GPU on a separate plane, and can be
    // moved around without re-rendering what's beneath them - which is more
    // efficient. However, not all hardware supports hardware cursors. For this
    // reason, wlroots provides a software fallback, which we ask it to render
    // here. wlr_cursor handles configuring hardware vs software cursors for you,
    // and this function is a no-op when hardware cursors are in use.
    c.wlr_output_render_software_cursors(output.wlr_output, null);

    // Conclude rendering and swap the buffers, showing the final frame
    // on-screen.
    c.wlr_renderer_end(wlr_renderer);
    // TODO: handle failure
    _ = c.wlr_output_commit(output.wlr_output);
}

/// Render all surfaces on the passed layer
fn renderLayer(output: Output, layer: std.TailQueue(LayerSurface), now: *c.timespec) void {
    var it = layer.first;
    while (it) |node| : (it = node.next) {
        const layer_surface = &node.data;
        var rdata = SurfaceRenderData{
            .output = &output,
            .output_x = layer_surface.box.x,
            .output_y = layer_surface.box.y,
            .when = now,
        };
        c.wlr_layer_surface_v1_for_each_surface(
            layer_surface.wlr_layer_surface,
            renderSurfaceIterator,
            &rdata,
        );
    }
}

fn renderView(output: Output, view: *View, now: *c.timespec) void {
    // If we have saved buffers, we are in the middle of a transaction
    // and need to render those buffers until the transaction is complete.
    if (view.saved_buffers.items.len != 0) {
        for (view.saved_buffers.items) |saved_buffer|
            renderTexture(
                output,
                saved_buffer.wlr_buffer.texture,
                .{
                    .x = saved_buffer.box.x + view.current.box.x - view.saved_surface_box.x,
                    .y = saved_buffer.box.y + view.current.box.y - view.saved_surface_box.y,
                    .width = @intCast(c_int, saved_buffer.box.width),
                    .height = @intCast(c_int, saved_buffer.box.height),
                },
                saved_buffer.transform,
            );
    } else {
        // Since there is no stashed buffer, we are not in the middle of
        // a transaction and may simply render each toplevel surface.
        var rdata = SurfaceRenderData{
            .output = &output,
            .output_x = view.current.box.x - view.surface_box.x,
            .output_y = view.current.box.y - view.surface_box.y,
            .when = now,
        };

        view.forEachSurface(renderSurfaceIterator, &rdata);
    }
}

/// Render all xwayland unmanaged windows that appear on the output
fn renderXwaylandUnmanaged(output: Output, now: *c.timespec) void {
    const root = output.root;
    const output_box: *c.wlr_box = c.wlr_output_layout_get_box(
        root.wlr_output_layout,
        output.wlr_output,
    );

    var it = output.root.xwayland_unmanaged_views.first;
    while (it) |node| : (it = node.next) {
        const wlr_xwayland_surface = node.data.wlr_xwayland_surface;

        var rdata = SurfaceRenderData{
            .output = &output,
            .output_x = wlr_xwayland_surface.x - output_box.x,
            .output_y = wlr_xwayland_surface.y - output_box.y,
            .when = now,
        };
        c.wlr_surface_for_each_surface(wlr_xwayland_surface.surface, renderSurfaceIterator, &rdata);
    }
}

/// This function is passed to wlroots to render each surface during iteration
fn renderSurfaceIterator(
    surface: ?*c.wlr_surface,
    surface_x: c_int,
    surface_y: c_int,
    data: ?*c_void,
) callconv(.C) void {
    const rdata = util.voidCast(SurfaceRenderData, data.?);

    renderTexture(
        rdata.output.*,
        c.wlr_surface_get_texture(surface),
        .{
            .x = rdata.output_x + surface_x,
            .y = rdata.output_y + surface_y,
            .width = surface.?.current.width,
            .height = surface.?.current.height,
        },
        surface.?.current.transform,
    );

    c.wlr_surface_send_frame_done(surface, rdata.when);
}

/// Render the given texture at the given box, taking the scale and transform
/// of the output into account.
fn renderTexture(
    output: Output,
    wlr_texture: ?*c.wlr_texture,
    wlr_box: c.wlr_box,
    transform: c.wl_output_transform,
) void {
    const texture = wlr_texture orelse return;
    var box = wlr_box;

    // Scale the box to the output's current scaling factor
    scaleBox(&box, output.wlr_output.scale);

    // wlr_matrix_project_box is a helper which takes a box with a desired
    // x, y coordinates, width and height, and an output geometry, then
    // prepares an orthographic projection and multiplies the necessary
    // transforms to produce a model-view-projection matrix.
    var matrix: [9]f32 = undefined;
    const inverted = c.wlr_output_transform_invert(transform);
    c.wlr_matrix_project_box(&matrix, &box, inverted, 0.0, &output.wlr_output.transform_matrix);

    // This takes our matrix, the texture, and an alpha, and performs the actual
    // rendering on the GPU.
    _ = c.wlr_render_texture_with_matrix(output.getRenderer(), texture, &matrix, 1.0);
}

fn renderBorders(output: Output, view: *View, now: *c.timespec) void {
    const config = &output.root.server.config;
    var border: Box = undefined;
    const color = if (view.focused)
        &output.root.server.config.border_color_focused
    else
        &output.root.server.config.border_color_unfocused;
    const border_width = output.root.server.config.border_width;

    // left and right, covering the corners as well
    border.y = view.current.box.y - @intCast(i32, border_width);
    border.width = border_width;
    border.height = view.current.box.height + border_width * 2;

    // left
    border.x = view.current.box.x - @intCast(i32, border_width);
    renderRect(output, border, color);

    // right
    border.x = view.current.box.x + @intCast(i32, view.current.box.width);
    renderRect(output, border, color);

    // top and bottom
    border.x = view.current.box.x;
    border.width = view.current.box.width;
    border.height = border_width;

    // top
    border.y = view.current.box.y - @intCast(i32, border_width);
    renderRect(output, border, color);

    // bottom border
    border.y = view.current.box.y + @intCast(i32, view.current.box.height);
    renderRect(output, border, color);
}

fn renderRect(output: Output, box: Box, color: *const [4]f32) void {
    var wlr_box = box.toWlrBox();
    scaleBox(&wlr_box, output.wlr_output.scale);
    c.wlr_render_rect(
        output.getRenderer(),
        &wlr_box,
        color,
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
