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

const Self = @This();

const std = @import("std");

const c = @import("c.zig");
const render = @import("render.zig");

const Box = @import("Box.zig");
const LayerSurface = @import("LayerSurface.zig");
const Log = @import("log.zig").Log;
const Root = @import("Root.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;

root: *Root,
wlr_output: *c.wlr_output,

/// All layer surfaces on the output, indexed by the layer enum.
layers: [4]std.TailQueue(LayerSurface),

/// The area left for views and other layer surfaces after applying the
/// exclusive zones of exclusive layer surfaces.
usable_box: Box,

/// The top of the stack is the "most important" view.
views: ViewStack(View),

/// A bit field of focused tags
current_focused_tags: u32,
pending_focused_tags: ?u32,

/// Number of views in "master" section of the screen.
master_count: u32,

/// Percentage of the total screen that the master section takes up.
master_factor: f64,

/// Current layout of the output.
layout: Layout,

// All listeners for this output, in alphabetical order
listen_destroy: c.wl_listener,
listen_frame: c.wl_listener,
listen_mode: c.wl_listener,

// All possible layouts.
pub const Layout = enum {
    TopMaster,
    RightMaster,
    BottomMaster,
    LeftMaster,
    Full,
};

const LayoutName = struct {
    name: []const u8,
    layout: Layout,
};

// zig fmt: off
const layout_names = [_]LayoutName {
    .{ .name = "TopMaster",    .layout = Layout.TopMaster, },
    .{ .name = "RightMaster",  .layout = Layout.RightMaster, },
    .{ .name = "BottomMaster", .layout = Layout.BottomMaster, },
    .{ .name = "LeftMaster",   .layout = Layout.LeftMaster, },
    .{ .name = "Full",         .layout = Layout.Full, },
};
// zig fmt: on

pub fn getLayoutByName(self: Self, name: []const u8) Layout {
    for (layout_names) |current| {
        if (std.mem.eql(u8, name, current.name)) {
            return current.layout;
        }
    }
    Log.Error.log("Layout '{}' does not exist", .{name});
    // In case of error default to LeftMaster
    return Layout.LeftMaster;
}

pub fn init(self: *Self, root: *Root, wlr_output: *c.wlr_output) !void {
    // Some backends don't have modes. DRM+KMS does, and we need to set a mode
    // before we can use the output. The mode is a tuple of (width, height,
    // refresh rate), and each monitor supports only a specific set of modes. We
    // just pick the monitor's preferred mode, a more sophisticated compositor
    // would let the user configure it.

    // if not empty
    if (c.wl_list_empty(&wlr_output.modes) == 0) {
        // TODO: handle failure
        const mode = c.wlr_output_preferred_mode(wlr_output);
        c.wlr_output_set_mode(wlr_output, mode);
        c.wlr_output_enable(wlr_output, true);
        if (!c.wlr_output_commit(wlr_output)) {
            return error.CantCommitWlrOutputMode;
        }
    }

    self.root = root;
    self.wlr_output = wlr_output;
    wlr_output.data = self;

    for (self.layers) |*layer| {
        layer.* = std.TailQueue(LayerSurface).init();
    }

    self.views.init();

    self.current_focused_tags = 1 << 0;
    self.pending_focused_tags = null;

    self.master_count = 1;

    self.master_factor = 0.6;

    // LeftMaster is the default layout for all outputs
    self.layout = Layout.LeftMaster;

    // Set up listeners
    self.listen_destroy.notify = handleDestroy;
    c.wl_signal_add(&wlr_output.events.destroy, &self.listen_destroy);

    self.listen_frame.notify = handleFrame;
    c.wl_signal_add(&wlr_output.events.frame, &self.listen_frame);

    self.listen_mode.notify = handleMode;
    c.wl_signal_add(&wlr_output.events.mode, &self.listen_mode);

    if (c.river_wlr_output_is_noop(wlr_output)) {
        // A noop output is always 0 x 0
        self.usable_box = .{
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
        };
    } else {
        // Add the new output to the layout. The add_auto function arranges outputs
        // from left-to-right in the order they appear. A more sophisticated
        // compositor would let the user configure the arrangement of outputs in the
        // layout. This automatically creates an output global on the wl_display.
        c.wlr_output_layout_add_auto(root.wlr_output_layout, wlr_output);

        var width: c_int = undefined;
        var height: c_int = undefined;
        c.wlr_output_effective_resolution(wlr_output, &width, &height);
        self.usable_box = .{
            .x = 0,
            .y = 0,
            .width = @intCast(u32, width),
            .height = @intCast(u32, height),
        };
    }
}

pub fn deinit(self: *Self) void {
    for (self.layers) |*layer| {
        while (layer.pop()) |layer_surface_node| {
            self.root.server.allocator.destroy(layer_surface_node);
        }
    }

    while (self.views.first) |node| {
        node.view.deinit();
        self.views.remove(node);
        self.root.server.allocator.destroy(node);
    }
}

pub fn getRenderer(self: Self) *c.wlr_renderer {
    return c.river_wlr_backend_get_renderer(self.wlr_output.backend);
}

const MasterPosition = enum {
    Top,
    Right,
    Bottom,
    Left,
};

/// Default layout of master-stack and slave-stack.
pub fn layoutMasterStack(self: *Self, visible_count: u32, output_tags: u32, position: MasterPosition) void {
    const master_count = std.math.min(self.master_count, visible_count);
    const slave_count = if (master_count >= visible_count) 0 else visible_count - master_count;

    const border_width = self.root.server.config.border_width;
    const view_padding = self.root.server.config.view_padding;
    const outer_padding = self.root.server.config.outer_padding;

    const layout_width = @intCast(u32, self.usable_box.width) - outer_padding * 2;
    const layout_height = @intCast(u32, self.usable_box.height) - outer_padding * 2;

    // Depending on position of the master area,
    // the *_stack_size is either width or height
    var master_stack_size: u32 = undefined;
    var slave_stack_size: u32 = undefined;
    if (master_count > 0 and slave_count > 0) {
        // If both master and slave views are present
        if (position == MasterPosition.Right or position == MasterPosition.Left) {
            master_stack_size = @floatToInt(u32, @round(@intToFloat(f64, layout_width) * self.master_factor));
            slave_stack_size = layout_width - master_stack_size;
        } else {
            master_stack_size = @floatToInt(u32, @round(@intToFloat(f64, layout_height) * self.master_factor));
            slave_stack_size = layout_height - master_stack_size;
        }
    } else if (master_count > 0) {
        if (position == MasterPosition.Right or position == MasterPosition.Left) {
            master_stack_size = layout_width;
        } else {
            master_stack_size = layout_height;
        }
        slave_stack_size = 0;
    } else {
        if (position == MasterPosition.Right or position == MasterPosition.Left) {
            slave_stack_size = layout_width;
        } else {
            slave_stack_size = layout_height;
        }
        master_stack_size = 0;
    }

    var i: u32 = 0;
    var it = ViewStack(View).pendingIterator(self.views.first, output_tags);
    while (it.next()) |node| {
        const view = &node.view;

        if (view.floating) {
            continue;
        }

        var new_box: Box = undefined;

        // Add the remainder to the first master/slave to ensure every
        // pixel of height is used
        if (i < master_count) {
            if (position == MasterPosition.Top) { // Top master
                const master_width = @divTrunc(layout_width, master_count);
                const master_width_rem = layout_width % master_count;
                new_box = .{
                    .x = @intCast(i32, i * master_width + if (i > 0) master_width_rem else 0),
                    .y = 0,
                    .width = master_width + if (i == 0) master_width_rem else 0,
                    .height = master_stack_size,
                };
            } else if (position == MasterPosition.Right) { // Right master
                const master_height = @divTrunc(layout_height, master_count);
                const master_height_rem = layout_height % master_count;
                new_box = .{
                    .x = @intCast(i32, slave_stack_size),
                    .y = @intCast(i32, i * master_height + if (i > 0) master_height_rem else 0),
                    .width = master_stack_size,
                    .height = master_height + if (i == 0) master_height_rem else 0,
                };
            } else if (position == MasterPosition.Bottom) { // Bottom master
                const master_width = @divTrunc(layout_width, master_count);
                const master_width_rem = layout_width % master_count;
                new_box = .{
                    .x = @intCast(i32, i * master_width + if (i > 0) master_width_rem else 0),
                    .y = @intCast(i32, slave_stack_size),
                    .width = master_width + if (i == 0) master_width_rem else 0,
                    .height = master_stack_size,
                };
            } else { // Left master
                const master_height = @divTrunc(layout_height, master_count);
                const master_height_rem = layout_height % master_count;
                new_box = .{
                    .x = 0,
                    .y = @intCast(i32, i * master_height + if (i > 0) master_height_rem else 0),
                    .width = master_stack_size,
                    .height = master_height + if (i == 0) master_height_rem else 0,
                };
            }
        } else {
            if (position == MasterPosition.Top) { // Top master
                const slave_width = @divTrunc(layout_width, slave_count);
                const slave_width_rem = layout_width % slave_count;
                new_box = .{
                    .x = @intCast(i32, (i - master_count) * slave_width + if (i > master_count) slave_width_rem else 0),
                    .y = @intCast(i32, master_stack_size),
                    .width = slave_width + if (i == master_count) slave_width_rem else 0,
                    .height = slave_stack_size,
                };
            } else if (position == MasterPosition.Right) { // Right master
                const slave_height = @divTrunc(layout_height, slave_count);
                const slave_height_rem = layout_height % slave_count;
                new_box = .{
                    .x = 0,
                    .y = @intCast(i32, (i - master_count) * slave_height + if (i > master_count) slave_height_rem else 0),
                    .width = slave_stack_size,
                    .height = slave_height + if (i == master_count) slave_height_rem else 0,
                };
            } else if (position == MasterPosition.Bottom) { // Bottom master
                const slave_width = @divTrunc(layout_width, slave_count);
                const slave_width_rem = layout_width % slave_count;
                new_box = .{
                    .x = @intCast(i32, (i - master_count) * slave_width + if (i > master_count) slave_width_rem else 0),
                    .y = 0,
                    .width = slave_width + if (i == master_count) slave_width_rem else 0,
                    .height = slave_stack_size,
                };
            } else { // Left master
                const slave_height = @divTrunc(layout_height, slave_count);
                const slave_height_rem = layout_height % slave_count;
                new_box = .{
                    .x = @intCast(i32, master_stack_size),
                    .y = @intCast(i32, (i - master_count) * slave_height + if (i > master_count) slave_height_rem else 0),
                    .width = slave_stack_size,
                    .height = slave_height + if (i == master_count) slave_height_rem else 0,
                };
            }
        }

        // Apply offsets from borders and padding
        const xy_offset = @intCast(i32, border_width + outer_padding + view_padding);
        new_box.x += self.usable_box.x + xy_offset;
        new_box.y += self.usable_box.y + xy_offset;

        // Reduce size to allow space for borders/padding
        const delta_size = (border_width + view_padding) * 2;
        new_box.width -= delta_size;
        new_box.height -= delta_size;

        // Set the view's pending box to the new dimensions
        view.pending_box = new_box;

        i += 1;
    }
}

/// Wrapper for default layout with master area on the top
pub fn layoutTopMaster(self: *Self, visible_count: u32, output_tags: u32) void {
    layoutMasterStack(self, visible_count, output_tags, MasterPosition.Top);
}

/// Wrapper for default layout with master area on the right
pub fn layoutRightMaster(self: *Self, visible_count: u32, output_tags: u32) void {
    layoutMasterStack(self, visible_count, output_tags, MasterPosition.Right);
}

/// Wrapper for default layout with master area on the bottom
pub fn layoutBottomMaster(self: *Self, visible_count: u32, output_tags: u32) void {
    layoutMasterStack(self, visible_count, output_tags, MasterPosition.Bottom);
}

/// Wrapper for default layout with master area on the left
pub fn layoutLeftMaster(self: *Self, visible_count: u32, output_tags: u32) void {
    layoutMasterStack(self, visible_count, output_tags, MasterPosition.Left);
}

/// A layout in which every window uses the maximum available space.
pub fn layoutFull(self: *Self, visible_count: u32, output_tags: u32) void {
    const border_width = self.root.server.config.border_width;
    const view_padding = self.root.server.config.view_padding;
    const outer_padding = self.root.server.config.outer_padding;

    const layout_width = @intCast(u32, self.usable_box.width) -
        (outer_padding * 2) - (border_width * 2) - (view_padding * 2);
    const layout_height = @intCast(u32, self.usable_box.height) -
        (outer_padding * 2) - (border_width * 2) - (view_padding * 2);
    const xy_offset = @intCast(i32, outer_padding + border_width + view_padding);

    var i: u32 = 0;
    var it = ViewStack(View).pendingIterator(self.views.first, output_tags);
    while (it.next()) |node| {
        const view = &node.view;

        if (view.floating) {
            continue;
        }

        var new_box: Box = undefined;
        new_box = .{
            .x = xy_offset,
            .y = xy_offset,
            .width = layout_width,
            .height = layout_height,
        };

        view.pending_box = new_box;

        i += 1;
    }
}

/// Arrange all views on the output for the current layout. Modifies only
/// pending state, the changes are not appplied until a transaction is started
/// and completed.
pub fn arrangeViews(self: *Self) void {
    // If the output has a zero dimension, trying to arrange would cause
    // underflow and is pointless anyway
    if (self.usable_box.width == 0 or self.usable_box.height == 0) {
        return;
    }

    const output_tags = if (self.pending_focused_tags) |tags|
        tags
    else
        self.current_focused_tags;

    const visible_count = blk: {
        var count: u32 = 0;
        var it = ViewStack(View).pendingIterator(self.views.first, output_tags);
        while (it.next()) |node| {
            if (node.view.floating) {
                continue;
            }
            count += 1;
        }
        break :blk count;
    };

    // A single view should always use the maximum available space. This is
    // implemented via the "full" layout to remove the need of every single
    // layout to explicitly handle this edge case or the other edge case of
    // no visible views.
    if (visible_count <= 1) {
        layoutFull(self, visible_count, output_tags);
        return;
    }

    switch (self.layout) {
        .Full => layoutFull(self, visible_count, output_tags),
        .TopMaster => layoutTopMaster(self, visible_count, output_tags),
        .RightMaster => layoutRightMaster(self, visible_count, output_tags),
        .BottomMaster => layoutBottomMaster(self, visible_count, output_tags),
        .LeftMaster => layoutLeftMaster(self, visible_count, output_tags),
    }
}

/// Arrange all layer surfaces of this output and addjust the usable aread
pub fn arrangeLayers(self: *Self) void {
    const full_box = blk: {
        var width: c_int = undefined;
        var height: c_int = undefined;
        c.wlr_output_effective_resolution(self.wlr_output, &width, &height);
        break :blk Box{
            .x = 0,
            .y = 0,
            .width = @intCast(u32, width),
            .height = @intCast(u32, height),
        };
    };

    // This box is modified as exclusive zones are applied
    var usable_box = full_box;

    const layer_idxs = [_]usize{
        c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
        c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
        c.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
        c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
    };

    // Arrange all layer surfaces with exclusive zones, applying them to the
    // usable box along the way.
    for (layer_idxs) |layer| {
        self.arrangeLayer(self.layers[layer], full_box, &usable_box, true);
    }

    // If the the usable_box has changed, we need to rearrange the output
    if (!std.meta.eql(self.usable_box, usable_box)) {
        self.usable_box = usable_box;
        self.root.arrange();
    }

    // Arrange the layers without exclusive zones
    for (layer_idxs) |layer| {
        self.arrangeLayer(self.layers[layer], full_box, &usable_box, false);
    }

    // Find the topmost layer surface in the top or overlay layers which
    // requests keyboard interactivity if any.
    const topmost_surface = outer: for (layer_idxs[0..2]) |layer| {
        // Iterate in reverse order since the last layer is rendered on top
        var it = self.layers[layer].last;
        while (it) |node| : (it = node.prev) {
            const layer_surface = &node.data;
            if (layer_surface.wlr_layer_surface.current.keyboard_interactive) {
                break :outer layer_surface;
            }
        }
    } else null;

    var it = self.root.server.input_manager.seats.first;
    while (it) |node| : (it = node.next) {
        const seat = &node.data;

        // Only grab focus of seats which have the output focused
        if (seat.focused_output != self) {
            continue;
        }

        if (topmost_surface) |to_focus| {
            // If we found a surface that requires focus, grab the focus of all
            // seats.
            seat.setFocusRaw(.{ .layer = to_focus });
        } else if (seat.focused_layer) |current_focus| {
            // If the seat is currently focusing a layer without keyboard
            // interactivity, clear the focused layer.
            if (!current_focus.wlr_layer_surface.current.keyboard_interactive) {
                seat.setFocusRaw(.{ .none = {} });
                seat.focus(null);
            }
        }
    }
}

/// Arrange the layer surfaces of a given layer
fn arrangeLayer(
    self: *Self,
    layer: std.TailQueue(LayerSurface),
    full_box: Box,
    usable_box: *Box,
    exclusive: bool,
) void {
    var it = layer.first;
    while (it) |node| : (it = node.next) {
        const layer_surface = &node.data;
        const current_state = layer_surface.wlr_layer_surface.current;

        // If the value of exclusive_zone is greater than zero, then it exclusivly
        // occupies some area of the screen.
        if (exclusive != (current_state.exclusive_zone > 0)) {
            continue;
        }

        // If the exclusive zone is set to -1, this means the the client would like
        // to ignore any exclusive zones and use the full area of the output.
        const bounds = if (current_state.exclusive_zone == -1) &full_box else usable_box;

        var new_box: Box = undefined;

        // Horizontal alignment
        const anchor_left = @intCast(u32, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
        const anchor_right = @intCast(u32, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
        if (current_state.desired_width == 0) {
            const anchor_left_right = anchor_left | anchor_right;
            if (current_state.anchor & anchor_left_right == anchor_left_right) {
                new_box.x = bounds.x + @intCast(i32, current_state.margin.left);
                new_box.width = bounds.width -
                    (current_state.margin.left + current_state.margin.right);
            } else {
                Log.Error.log(
                    "Protocol Error: layer surface '{}' requested width 0 without anchoring to opposite edges.",
                    .{layer_surface.wlr_layer_surface.namespace},
                );
                c.wlr_layer_surface_v1_close(layer_surface.wlr_layer_surface);
                continue;
            }
        } else if (current_state.anchor & anchor_left != 0) {
            new_box.x = bounds.x + @intCast(i32, current_state.margin.left);
            new_box.width = current_state.desired_width;
        } else if (current_state.anchor & anchor_right != 0) {
            new_box.x = bounds.x + @intCast(i32, bounds.width - current_state.desired_width -
                current_state.margin.right);
            new_box.width = current_state.desired_width;
        } else {
            new_box.x = bounds.x + @intCast(i32, bounds.width / 2 - current_state.desired_width / 2);
            new_box.width = current_state.desired_width;
        }

        // Vertical alignment
        const anchor_top = @intCast(u32, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP);
        const anchor_bottom = @intCast(u32, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM);
        if (current_state.desired_height == 0) {
            const anchor_top_bottom = anchor_top | anchor_bottom;
            if (current_state.anchor & anchor_top_bottom == anchor_top_bottom) {
                new_box.y = bounds.y + @intCast(i32, current_state.margin.top);
                new_box.height = bounds.height -
                    (current_state.margin.top + current_state.margin.bottom);
            } else {
                Log.Error.log(
                    "Protocol Error: layer surface '{}' requested height 0 without anchoring to opposite edges.",
                    .{layer_surface.wlr_layer_surface.namespace},
                );
                c.wlr_layer_surface_v1_close(layer_surface.wlr_layer_surface);
                continue;
            }
        } else if (current_state.anchor & anchor_top != 0) {
            new_box.y = bounds.y + @intCast(i32, current_state.margin.top);
            new_box.height = current_state.desired_height;
        } else if (current_state.anchor & anchor_bottom != 0) {
            new_box.y = bounds.y + @intCast(i32, bounds.height - current_state.desired_height -
                current_state.margin.bottom);
            new_box.height = current_state.desired_height;
        } else {
            new_box.y = bounds.y + @intCast(i32, bounds.height / 2 - current_state.desired_height / 2);
            new_box.height = current_state.desired_height;
        }

        layer_surface.box = new_box;

        // Apply the exclusive zone to the current bounds
        const edges = [4]struct {
            anchors: u32,
            to_increase: ?*i32,
            to_decrease: ?*u32,
            margin: u32,
        }{
            .{
                .anchors = anchor_left | anchor_right | anchor_top,
                .to_increase = &usable_box.y,
                .to_decrease = &usable_box.height,
                .margin = current_state.margin.top,
            },
            .{
                .anchors = anchor_left | anchor_right | anchor_bottom,
                .to_increase = null,
                .to_decrease = &usable_box.height,
                .margin = current_state.margin.bottom,
            },
            .{
                .anchors = anchor_left | anchor_top | anchor_bottom,
                .to_increase = &usable_box.x,
                .to_decrease = &usable_box.width,
                .margin = current_state.margin.left,
            },
            .{
                .anchors = anchor_right | anchor_top | anchor_bottom,
                .to_increase = null,
                .to_decrease = &usable_box.width,
                .margin = current_state.margin.right,
            },
        };

        for (edges) |edge| {
            if (current_state.anchor & edge.anchors == edge.anchors and
                current_state.exclusive_zone + @intCast(i32, edge.margin) > 0)
            {
                const delta = current_state.exclusive_zone + @intCast(i32, edge.margin);
                if (edge.to_increase) |value| {
                    value.* += delta;
                }
                if (edge.to_decrease) |value| {
                    value.* -= @intCast(u32, delta);
                }
            }
        }

        // Tell the client to assume the new size
        Log.Debug.log("send configure, {} x {}", .{ layer_surface.box.width, layer_surface.box.height });
        c.wlr_layer_surface_v1_configure(
            layer_surface.wlr_layer_surface,
            layer_surface.box.width,
            layer_surface.box.height,
        );
    }
}

/// Called when the output is destroyed. Evacuate all views from the output
/// and then remove it from the list of outputs.
fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_destroy", listener.?);
    const root = self.root;

    Log.Debug.log("Output {} destroyed", .{self.wlr_output.name});

    // Use the first output in the list that is not the one being destroyed.
    // If there is no other real output, use the noop output.
    var output_it = root.outputs.first;
    const fallback_output = while (output_it) |output_node| : (output_it = output_node.next) {
        if (&output_node.data != self) {
            break &output_node.data;
        }
    } else &root.noop_output;

    // Move all views from the destroyed output to the fallback one
    while (self.views.last) |node| {
        const view = &node.view;
        view.sendToOutput(fallback_output);
    }

    // Close all layer surfaces on the destroyed output
    for (self.layers) |*layer, layer_idx| {
        while (layer.pop()) |node| {
            const layer_surface = &node.data;
            // We need to move the closing layer surface to the noop output
            // since it may not be immediately destoryed. This just a request
            // to close which will trigger unmap and destroy events in
            // response, and the LayerSurface needs a valid output to
            // handle them.
            root.noop_output.layers[layer_idx].prepend(node);
            layer_surface.output = &root.noop_output;
            c.wlr_layer_surface_v1_close(layer_surface.wlr_layer_surface);
        }
    }

    // If any seat has the destroyed output focused, focus the fallback one
    var seat_it = root.server.input_manager.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        const seat = &seat_node.data;
        if (seat.focused_output == self) {
            seat.focused_output = fallback_output;
            seat.focus(null);
        }
    }

    // Remove all listeners
    c.wl_list_remove(&self.listen_destroy.link);
    c.wl_list_remove(&self.listen_frame.link);
    c.wl_list_remove(&self.listen_mode.link);

    // Clean up the wlr_output
    self.wlr_output.data = null;

    // Remove the destroyed output from the list
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    root.outputs.remove(node);
    root.server.allocator.destroy(node);

    // Arrange the root in case evacuated views affect the layout
    root.arrange();
}

fn handleFrame(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This function is called every time an output is ready to display a frame,
    // generally at the output's refresh rate (e.g. 60Hz).
    const self = @fieldParentPtr(Self, "listen_frame", listener.?);
    render.renderOutput(self);
}

fn handleMode(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_mode", listener.?);
    self.arrangeLayers();
    self.root.arrange();
}
