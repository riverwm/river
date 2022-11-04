// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
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
const os = std.os;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const pixman = @import("pixman");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const LayerSurface = @import("LayerSurface.zig");
const Output = @import("Output.zig");
const Server = @import("Server.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;

const log = std.log.scoped(.render);

const SurfaceRenderData = struct {
    output: *const Output,

    /// In output layout coordinates relative to the output
    output_x: i32,
    output_y: i32,

    when: *os.timespec,
};

/// The rendering order in this function must be kept in sync with Cursor.surfaceAt()
pub fn renderOutput(output: *Output) void {
    var now: os.timespec = undefined;
    os.clock_gettime(os.CLOCK.MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");

    var needs_frame: bool = undefined;
    var damage_region: pixman.Region32 = undefined;
    damage_region.init();
    defer damage_region.deinit();
    output.damage.?.attachRender(&needs_frame, &damage_region) catch {
        log.err("failed to attach renderer", .{});
        return;
    };

    if (!needs_frame) {
        output.wlr_output.rollback();
        return;
    }

    server.renderer.begin(@intCast(u32, output.wlr_output.width), @intCast(u32, output.wlr_output.height));

    // In order to avoid flashing a blank black screen as the session is locked
    // continue to render the unlocked session until either a lock surface is
    // created or waiting for lock surfaces times out.
    if (server.lock_manager.state == .locked or
        (server.lock_manager.state == .waiting_for_lock_surfaces and output.lock_surface != null) or
        server.lock_manager.state == .waiting_for_blank)
    {
        server.renderer.clear(&[_]f32{ 0, 0, 0, 1 }); // solid black

        // TODO: this isn't frame-perfect if the output mode is changed. We
        // could possibly delay rendering new frames after the mode change
        // until the surface commits a buffer of the correct size.
        if (output.lock_surface) |lock_surface| {
            var rdata = SurfaceRenderData{
                .output = output,
                .output_x = 0,
                .output_y = 0,
                .when = &now,
            };
            lock_surface.wlr_lock_surface.surface.forEachSurface(
                *SurfaceRenderData,
                renderSurfaceIterator,
                &rdata,
            );
        }

        renderDragIcons(output, &now);

        output.wlr_output.renderSoftwareCursors(null);
        server.renderer.end();
        output.wlr_output.commit() catch {
            log.err("output commit failed for {s}", .{output.wlr_output.name});
            return;
        };

        if (server.lock_manager.state == .locked) {
            switch (output.lock_render_state) {
                .unlocked, .pending_blank, .pending_lock_surface => unreachable,
                .blanked, .lock_surface => {},
            }
        } else {
            if (output.lock_surface == null) {
                output.lock_render_state = .pending_blank;
            } else {
                output.lock_render_state = .pending_lock_surface;
            }
        }

        return;
    }
    output.lock_render_state = .unlocked;

    // Find the first visible fullscreen view in the stack if there is one
    var it = ViewStack(View).iter(output.views.first, .forward, output.current.tags, renderFilter);
    const fullscreen_view = while (it.next()) |view| {
        if (view.current.fullscreen) break view;
    } else null;

    // If we have a fullscreen view to render, render it.
    if (fullscreen_view) |view| {
        // Always clear with solid black for fullscreen
        server.renderer.clear(&[_]f32{ 0, 0, 0, 1 });
        renderView(output, view, &now);
        if (build_options.xwayland) renderXwaylandOverrideRedirect(output, &now);
    } else {
        // No fullscreen view, so render normal layers/views
        server.renderer.clear(&server.config.background_color);

        renderLayer(output, output.getLayer(.background).*, &now, .toplevels);
        renderLayer(output, output.getLayer(.bottom).*, &now, .toplevels);

        // The first view in the list is "on top" so always iterate in reverse.

        // non-focused, non-floating views
        it = ViewStack(View).iter(output.views.last, .reverse, output.current.tags, renderFilter);
        while (it.next()) |view| {
            if (view.current.focus != 0 or view.current.float) continue;
            if (view.draw_borders) renderBorders(output, view);
            renderView(output, view, &now);
        }

        // focused, non-floating views
        it = ViewStack(View).iter(output.views.last, .reverse, output.current.tags, renderFilter);
        while (it.next()) |view| {
            if (view.current.focus == 0 or view.current.float) continue;
            if (view.draw_borders) renderBorders(output, view);
            renderView(output, view, &now);
        }

        // non-focused, floating views
        it = ViewStack(View).iter(output.views.last, .reverse, output.current.tags, renderFilter);
        while (it.next()) |view| {
            if (view.current.focus != 0 or !view.current.float) continue;
            if (view.draw_borders) renderBorders(output, view);
            renderView(output, view, &now);
        }

        // focused, floating views
        it = ViewStack(View).iter(output.views.last, .reverse, output.current.tags, renderFilter);
        while (it.next()) |view| {
            if (view.current.focus == 0 or !view.current.float) continue;
            if (view.draw_borders) renderBorders(output, view);
            renderView(output, view, &now);
        }

        if (build_options.xwayland) renderXwaylandOverrideRedirect(output, &now);

        renderLayer(output, output.getLayer(.top).*, &now, .toplevels);

        renderLayer(output, output.getLayer(.background).*, &now, .popups);
        renderLayer(output, output.getLayer(.bottom).*, &now, .popups);
        renderLayer(output, output.getLayer(.top).*, &now, .popups);
    }

    // The overlay layer is rendered in both fullscreen and normal cases
    renderLayer(output, output.getLayer(.overlay).*, &now, .toplevels);
    renderLayer(output, output.getLayer(.overlay).*, &now, .popups);

    renderDragIcons(output, &now);

    output.wlr_output.renderSoftwareCursors(null);

    server.renderer.end();

    output.wlr_output.commit() catch
        log.err("output commit failed for {s}", .{output.wlr_output.name});
}

fn renderFilter(view: *View, filter_tags: u32) bool {
    // This check prevents a race condition when a frame is requested
    // between mapping of a view and the first configure being handled.
    if (view.current.box.width == 0 or view.current.box.height == 0)
        return false;
    return view.current.tags & filter_tags != 0;
}

/// Render all surfaces on the passed layer
fn renderLayer(
    output: *const Output,
    layer: std.TailQueue(LayerSurface),
    now: *os.timespec,
    role: enum { toplevels, popups },
) void {
    var it = layer.first;
    while (it) |node| : (it = node.next) {
        const layer_surface = &node.data;
        var rdata = SurfaceRenderData{
            .output = output,
            .output_x = layer_surface.box.x,
            .output_y = layer_surface.box.y,
            .when = now,
        };
        switch (role) {
            .toplevels => layer_surface.wlr_layer_surface.surface.forEachSurface(
                *SurfaceRenderData,
                renderSurfaceIterator,
                &rdata,
            ),
            .popups => layer_surface.wlr_layer_surface.forEachPopupSurface(
                *SurfaceRenderData,
                renderSurfaceIterator,
                &rdata,
            ),
        }
    }
}

/// Render all surfaces in the view's surface tree, including subsurfaces and popups
fn renderView(output: *const Output, view: *View, now: *os.timespec) void {
    // If we have saved buffers, we are in the middle of a transaction
    // and need to render those buffers until the transaction is complete.
    if (view.saved_buffers.items.len != 0) {
        for (view.saved_buffers.items) |saved_buffer| {
            const texture = saved_buffer.client_buffer.texture orelse continue;
            renderTexture(
                output,
                texture,
                .{
                    .x = saved_buffer.surface_box.x + view.current.box.x - view.saved_surface_box.x,
                    .y = saved_buffer.surface_box.y + view.current.box.y - view.saved_surface_box.y,
                    .width = saved_buffer.surface_box.width,
                    .height = saved_buffer.surface_box.height,
                },
                &saved_buffer.source_box,
                saved_buffer.transform,
            );
        }
    } else {
        // Since there are no stashed buffers, we are not in the middle of
        // a transaction and may simply render the most recent buffers provided
        // by the client.
        var rdata = SurfaceRenderData{
            .output = output,
            .output_x = view.current.box.x - view.surface_box.x,
            .output_y = view.current.box.y - view.surface_box.y,
            .when = now,
        };
        view.forEachSurface(*SurfaceRenderData, renderSurfaceIterator, &rdata);
    }
}

fn renderDragIcons(output: *const Output, now: *os.timespec) void {
    var output_box: wlr.Box = undefined;
    server.root.output_layout.getBox(output.wlr_output, &output_box);

    var it = server.input_manager.seats.first;
    while (it) |node| : (it = node.next) {
        const icon = node.data.drag_icon orelse continue;

        var lx: f64 = undefined;
        var ly: f64 = undefined;
        switch (icon.wlr_drag_icon.drag.grab_type) {
            .keyboard_pointer => {
                lx = icon.seat.cursor.wlr_cursor.x;
                ly = icon.seat.cursor.wlr_cursor.y;
            },
            .keyboard_touch => {
                const touch_id = icon.wlr_drag_icon.drag.touch_id;
                const point = icon.seat.cursor.touch_points.get(touch_id) orelse continue;
                lx = point.lx;
                ly = point.ly;
            },
            .keyboard => unreachable,
        }

        var rdata = SurfaceRenderData{
            .output = output,
            .output_x = @floatToInt(i32, lx) + icon.sx - output_box.x,
            .output_y = @floatToInt(i32, ly) + icon.sy - output_box.y,
            .when = now,
        };
        icon.wlr_drag_icon.surface.forEachSurface(*SurfaceRenderData, renderSurfaceIterator, &rdata);
    }
}

/// Render all override redirect xwayland windows that appear on the output
fn renderXwaylandOverrideRedirect(output: *const Output, now: *os.timespec) void {
    var output_box: wlr.Box = undefined;
    server.root.output_layout.getBox(output.wlr_output, &output_box);

    var it = server.root.xwayland_override_redirect_views.last;
    while (it) |node| : (it = node.prev) {
        const xwayland_surface = node.data.xwayland_surface;

        var rdata = SurfaceRenderData{
            .output = output,
            .output_x = xwayland_surface.x - output_box.x,
            .output_y = xwayland_surface.y - output_box.y,
            .when = now,
        };
        xwayland_surface.surface.?.forEachSurface(*SurfaceRenderData, renderSurfaceIterator, &rdata);
    }
}

/// This function is passed to wlroots to render each surface during iteration
fn renderSurfaceIterator(
    surface: *wlr.Surface,
    surface_x: c_int,
    surface_y: c_int,
    rdata: *SurfaceRenderData,
) void {
    const texture = surface.getTexture() orelse return;

    var source_box: wlr.FBox = undefined;
    surface.getBufferSourceBox(&source_box);

    renderTexture(
        rdata.output,
        texture,
        .{
            .x = rdata.output_x + surface_x,
            .y = rdata.output_y + surface_y,
            .width = surface.current.width,
            .height = surface.current.height,
        },
        &source_box,
        surface.current.transform,
    );

    surface.sendFrameDone(rdata.when);
}

/// Render the given texture at the given box, taking the scale and transform
/// of the output into account.
fn renderTexture(
    output: *const Output,
    texture: *wlr.Texture,
    dest_box: wlr.Box,
    source_box: *const wlr.FBox,
    transform: wl.Output.Transform,
) void {
    var box = dest_box;

    // Scale the box to the output's current scaling factor
    scaleBox(&box, output.wlr_output.scale);

    // wlr_matrix_project_box is a helper which takes a box with a desired
    // x, y coordinates, width and height, and an output geometry, then
    // prepares an orthographic projection and multiplies the necessary
    // transforms to produce a model-view-projection matrix.
    var matrix: [9]f32 = undefined;
    const inverted = wlr.Output.transformInvert(transform);
    wlr.matrix.projectBox(&matrix, &box, inverted, 0.0, &output.wlr_output.transform_matrix);

    // This takes our matrix, the texture, and an alpha, and performs the actual
    // rendering on the GPU.
    server.renderer.renderSubtextureWithMatrix(texture, source_box, &matrix, 1.0) catch return;
}

fn renderBorders(output: *const Output, view: *View) void {
    const config = &server.config;
    const color = blk: {
        if (view.current.urgent) break :blk &config.border_color_urgent;
        if (view.current.focus != 0) break :blk &config.border_color_focused;
        break :blk &config.border_color_unfocused;
    };
    const actual_box = if (view.saved_buffers.items.len != 0) view.saved_surface_box else view.surface_box;

    var border: wlr.Box = undefined;

    // left and right, covering the corners as well
    border.y = view.current.box.y - config.border_width;
    border.width = config.border_width;
    border.height = actual_box.height + config.border_width * 2;

    // left
    border.x = view.current.box.x - config.border_width;
    renderRect(output, border, color);

    // right
    border.x = view.current.box.x + actual_box.width;
    renderRect(output, border, color);

    // top and bottom
    border.x = view.current.box.x;
    border.width = actual_box.width;
    border.height = config.border_width;

    // top
    border.y = view.current.box.y - config.border_width;
    renderRect(output, border, color);

    // bottom border
    border.y = view.current.box.y + actual_box.height;
    renderRect(output, border, color);
}

fn renderRect(output: *const Output, box: wlr.Box, color: *const [4]f32) void {
    var scaled = box;
    scaleBox(&scaled, output.wlr_output.scale);
    server.renderer.renderRect(&scaled, color, &output.wlr_output.transform_matrix);
}

/// Scale a wlr_box, taking the possibility of fractional scaling into account.
fn scaleBox(box: *wlr.Box, scale: f64) void {
    box.width = scaleLength(box.width, box.x, scale);
    box.height = scaleLength(box.height, box.y, scale);
    box.x = @floatToInt(c_int, @round(@intToFloat(f64, box.x) * scale));
    box.y = @floatToInt(c_int, @round(@intToFloat(f64, box.y) * scale));
}

/// Scales a width/height.
///
/// This might seem overly complex, but it needs to work for fractional scaling.
fn scaleLength(length: c_int, offset: c_int, scale: f64) c_int {
    return @floatToInt(c_int, @round(@intToFloat(f64, offset + length) * scale) -
        @round(@intToFloat(f64, offset) * scale));
}
