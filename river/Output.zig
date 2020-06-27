// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
// Copyright 2020 Leon Henrik Plickat
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
const log = @import("log.zig");
const render = @import("render.zig");
const util = @import("util.zig");

const Box = @import("Box.zig");
const LayerSurface = @import("LayerSurface.zig");
const Root = @import("Root.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const OutputStatus = @import("OutputStatus.zig");

// Minimum width/height for surfaces.
// This is needed, because external layouts and large padding and border sizes
// may cause surfaces so small, that bugs in client applications are encountered,
// or even surfaces of zero or negative size,which are a protocol error and would
// likely cause river to crash. The value is totally arbitrary and low enough,
// that it should never be encountered during normal usage.
const minimum_size = 50;

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

/// Current layout of the output. If it is "full", river will use the full
/// layout. Otherwise river assumes it contains a string which, when executed
/// with sh, will result in a layout.
layout: []const u8,

/// List of status tracking objects relaying changes to this output to clients.
status_trackers: std.SinglyLinkedList(OutputStatus),

// All listeners for this output, in alphabetical order
listen_destroy: c.wl_listener,
listen_frame: c.wl_listener,
listen_mode: c.wl_listener,

pub fn init(self: *Self, root: *Root, wlr_output: *c.wlr_output) !void {
    // Some backends don't have modes. DRM+KMS does, and we need to set a mode
    // before we can use the output. The mode is a tuple of (width, height,
    // refresh rate), and each monitor supports only a specific set of modes. We
    // just pick the monitor's preferred mode, a more sophisticated compositor
    // would let the user configure it.
    if (c.wlr_output_preferred_mode(wlr_output)) |mode| {
        c.wlr_output_set_mode(wlr_output, mode);
        c.wlr_output_enable(wlr_output, true);
        if (!c.wlr_output_commit(wlr_output)) return error.OutputCommitFailed;
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

    self.layout = try std.mem.dupe(util.gpa, u8, "full");

    self.status_trackers = std.SinglyLinkedList(OutputStatus).init();

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

pub fn getRenderer(self: Self) *c.wlr_renderer {
    return c.river_wlr_backend_get_renderer(self.wlr_output.backend);
}

pub fn sendViewTags(self: Self) void {
    var it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendViewTags();
}

/// The single build in layout, which makes all views use the maximum available
/// space.
fn layoutFull(self: *Self, visible_count: u32, output_tags: u32) void {
    const border_width = self.root.server.config.border_width;
    const view_padding = self.root.server.config.view_padding;
    const outer_padding = self.root.server.config.outer_padding;
    const xy_offset = outer_padding + border_width + view_padding;

    var full_box: Box = .{
        .x = self.usable_box.x + @intCast(i32, xy_offset),
        .y = self.usable_box.y + @intCast(i32, xy_offset),
        .width = self.usable_box.width - (2 * xy_offset),
        .height = self.usable_box.height - (2 * xy_offset),
    };

    // Apply minimum view size
    if (full_box.width < minimum_size) {
        full_box.width = minimum_size;
    }
    if (full_box.height < minimum_size) {
        full_box.height = minimum_size;
    }

    var it = ViewStack(View).pendingIterator(self.views.first, output_tags);
    while (it.next()) |node| {
        const view = &node.view;
        if (view.mode == .layout) view.pending_box = full_box;
    }
}

const LayoutError = error{
    BadExitCode,
    BadWindowConfiguration,
    ConfigurationMismatch,
};

/// Parse a window configuration string and write values to the box
fn parseWindowConfig(buffer: []const u8) LayoutError!Box {
    var i: u32 = 0;
    var box: Box = undefined;
    var it = std.mem.split(buffer, " ");
    while (it.next()) |token| : (i += 1) {
        switch (i) {
            0 => box.x = std.fmt.parseInt(i32, token, 10) catch return LayoutError.BadWindowConfiguration,
            1 => box.y = std.fmt.parseInt(i32, token, 10) catch return LayoutError.BadWindowConfiguration,
            2 => box.width = std.fmt.parseInt(u32, token, 10) catch return LayoutError.BadWindowConfiguration,
            3 => box.height = std.fmt.parseInt(u32, token, 10) catch return LayoutError.BadWindowConfiguration,
            else => {},
        }
    }
    if (i != 4) return LayoutError.BadWindowConfiguration;
    return box;
}

test "parse window configuration" {
    const testing = @import("std").testing;
    var box = try parseWindowConfig("5 10 100 200");
    testing.expect(box.x == 5);
    testing.expect(box.y == 10);
    testing.expect(box.width == 100);
    testing.expect(box.height == 200);
}

/// Execute an external layout function, parse its output and apply the layout
/// to the output.
fn layoutExternal(self: *Self, visible_count: u32, output_tags: u32) !void {
    const config = self.root.server.config;
    const xy_offset = @intCast(i32, config.border_width + config.outer_padding + config.view_padding);
    const delta_size = (config.border_width + config.view_padding) * 2;
    const layout_width = @intCast(u32, self.usable_box.width) - config.outer_padding * 2;
    const layout_height = @intCast(u32, self.usable_box.height) - config.outer_padding * 2;

    var arena = std.heap.ArenaAllocator.init(util.gpa);
    defer arena.deinit();

    // Assemble command
    const layout_command = std.fmt.allocPrint(&arena.allocator, "{} {} {} {d} {} {}", .{
        self.layout,
        visible_count,
        self.master_count,
        self.master_factor,
        layout_width,
        layout_height,
    }) catch @panic("Out of memory.");
    const cmd = [_][]const u8{ "/bin/sh", "-c", layout_command };

    // Execute layout executable
    // TODO abort after 1 second
    const child = try std.ChildProcess.init(&cmd, &arena.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    try std.ChildProcess.spawn(child);
    const max_output_size = 400 * 1024;
    const buffer = try child.stdout.?.inStream().readAllAlloc(&arena.allocator, max_output_size);
    const term = try child.wait();
    switch (term) {
        .Exited, .Signal, .Stopped, .Unknown => |code| {
            if (code != 0) {
                return LayoutError.BadExitCode;
            }
        },
    }

    // Parse layout command output
    var view_boxen = std.ArrayList(Box).init(&arena.allocator);
    var parse_it = std.mem.split(buffer, "\n");
    while (parse_it.next()) |token| {
        if (std.mem.eql(u8, token, "")) break;
        var box = try parseWindowConfig(token);
        box.x += self.usable_box.x + xy_offset;
        box.y += self.usable_box.y + xy_offset;
        box.width -= delta_size;
        box.height -= delta_size;
        if (box.width < minimum_size) {
            box.width = minimum_size;
            log.notice(.layout, "window hits minimum view width.", .{});
        }
        if (box.height < minimum_size) {
            box.height = minimum_size;
            log.notice(.layout, "window hits minimum view height.", .{});
        }
        try view_boxen.append(box);
    }

    if (view_boxen.items.len != visible_count) return LayoutError.ConfigurationMismatch;

    // Apply window configuration to views
    var i: u32 = 0;
    var view_it = ViewStack(View).pendingIterator(self.views.first, output_tags);
    while (view_it.next()) |node| {
        const view = &node.view;
        if (view.mode == .layout) {
            view.pending_box = view_boxen.items[i];
            i += 1;
        }
    }
}

/// Arrange all views on the output for the current layout. Modifies only
/// pending state, the changes are not appplied until a transaction is started
/// and completed.
pub fn arrangeViews(self: *Self) void {
    // If the output has a zero dimension, trying to arrange would cause
    // an underflow and is pointless anyway.
    if (self.usable_box.width == 0 or self.usable_box.height == 0) return;

    const output_tags = if (self.pending_focused_tags) |tags|
        tags
    else
        self.current_focused_tags;

    const visible_count = blk: {
        var count: u32 = 0;
        var it = ViewStack(View).pendingIterator(self.views.first, output_tags);
        while (it.next()) |node| {
            if (node.view.mode == .layout) count += 1;
        }
        break :blk count;
    };

    if (visible_count == 0) return;

    if (std.mem.eql(u8, self.layout, "full")) return layoutFull(self, visible_count, output_tags);

    layoutExternal(self, visible_count, output_tags) catch |err| {
        switch (err) {
            LayoutError.BadExitCode => log.err(.layout, "layout command exited with non-zero return code", .{}),
            LayoutError.BadWindowConfiguration => log.err(.layout, "invalid window configuration", .{}),
            LayoutError.ConfigurationMismatch => log.err(.layout, "mismatch between window configuration and visible window counts", .{}),
            else => log.err(.layout, "'{}' error while trying to use external layout", .{err}),
        }
        log.err(.layout, "falling back to internal layout", .{});
        layoutFull(self, visible_count, output_tags);
    };
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
                log.err(
                    .layer_shell,
                    "protocol error: layer surface '{}' requested width 0 without anchoring to opposite edges",
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
                log.err(
                    .layer_shell,
                    "protocol error: layer surface '{}' requested height 0 without anchoring to opposite edges",
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
        log.debug(.layer_shell, "send configure, {} x {}", .{ layer_surface.box.width, layer_surface.box.height });
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

    log.debug(.server, "output '{}' destroyed", .{self.wlr_output.name});

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
            seat.focusOutput(self);
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
    util.gpa.destroy(node);

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
