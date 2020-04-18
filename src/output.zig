const std = @import("std");
const c = @import("c.zig");
const render = @import("render.zig");

const Box = @import("box.zig").Box;
const LayerSurface = @import("layer_surface.zig").LayerSurface;
const Log = @import("log.zig").Log;
const Root = @import("root.zig").Root;
const View = @import("view.zig").View;
const ViewStack = @import("view_stack.zig").ViewStack;

pub const Output = struct {
    const Self = @This();

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

        self.usable_box = .{
            .x = 0,
            .y = 0,
            .width = 1920,
            .height = 1080,
        };

        self.views.init();

        self.current_focused_tags = 1 << 0;
        self.pending_focused_tags = null;

        self.master_count = 1;

        self.master_factor = 0.6;

        // Set up listeners
        self.listen_destroy.notify = handleDestroy;
        c.wl_signal_add(&wlr_output.events.destroy, &self.listen_destroy);

        self.listen_frame.notify = handleFrame;
        c.wl_signal_add(&wlr_output.events.frame, &self.listen_frame);

        self.listen_mode.notify = handleMode;
        c.wl_signal_add(&wlr_output.events.mode, &self.listen_mode);

        if (!c.river_wlr_output_is_noop(wlr_output)) {
            // Add the new output to the layout. The add_auto function arranges outputs
            // from left-to-right in the order they appear. A more sophisticated
            // compositor would let the user configure the arrangement of outputs in the
            // layout. This automatically creates an output global on the wl_display.
            c.wlr_output_layout_add_auto(root.wlr_output_layout, wlr_output);
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

    /// Add a new view to the output. arrangeViews() will be called by the view
    /// when it is mapped.
    pub fn addView(self: *Self, wlr_xdg_surface: *c.wlr_xdg_surface) void {
        const node = self.root.server.allocator.create(ViewStack(View).Node) catch unreachable;
        node.view.init(self, wlr_xdg_surface, self.current_focused_tags);
        self.views.push(node);
    }

    /// Add a newly created layer surface to the output.
    pub fn addLayerSurface(self: *Self, wlr_layer_surface: *c.wlr_layer_surface_v1) !void {
        const layer = wlr_layer_surface.client_pending.layer;
        const node = try self.layers[@intCast(usize, @enumToInt(layer))].allocateNode(self.root.server.allocator);
        node.data.init(self, wlr_layer_surface, layer);
        self.layers[@intCast(usize, @enumToInt(layer))].append(node);
        self.arrangeLayers();
    }

    pub fn arrange(self: *Self) void {
        self.arrangeViews();
    }

    /// Arrange all views on the output for the current layout. Modifies only
    /// pending state, the changes are not appplied until a transaction is started
    /// and completed.
    fn arrangeViews(self: *Self) void {
        const output_tags = if (self.pending_focused_tags) |tags|
            tags
        else
            self.current_focused_tags;

        const visible_count = blk: {
            var count: u32 = 0;
            var it = ViewStack(View).pendingIterator(self.views.first, output_tags);
            while (it.next() != null) count += 1;
            break :blk count;
        };

        const master_count = std.math.min(self.master_count, visible_count);
        const slave_count = if (master_count >= visible_count) 0 else visible_count - master_count;

        const outer_padding = self.root.server.config.outer_padding;

        const layout_width = @intCast(u32, self.usable_box.width) - outer_padding * 2;
        const layout_height = @intCast(u32, self.usable_box.height) - outer_padding * 2;

        var master_column_width: u32 = undefined;
        var slave_column_width: u32 = undefined;
        if (master_count > 0 and slave_count > 0) {
            // If both master and slave views are present
            master_column_width = @floatToInt(u32, @round(@intToFloat(f64, layout_width) * self.master_factor));
            slave_column_width = layout_width - master_column_width;
        } else if (master_count > 0) {
            master_column_width = layout_width;
            slave_column_width = 0;
        } else {
            slave_column_width = layout_width;
            master_column_width = 0;
        }

        var i: u32 = 0;
        var it = ViewStack(View).pendingIterator(self.views.first, output_tags);
        while (it.next()) |node| {
            const view = &node.view;
            if (i < master_count) {
                // Add the remainder to the first master to ensure every pixel of height is used
                const master_height = @divTrunc(layout_height, master_count);
                const master_height_rem = layout_height % master_count;

                view.pending_box = Box{
                    .x = @intCast(i32, outer_padding),
                    .y = @intCast(i32, outer_padding + i * master_height +
                        if (i > 0) master_height_rem else 0),

                    .width = master_column_width,
                    .height = master_height + if (i == 0) master_height_rem else 0,
                };
            } else {
                // Add the remainder to the first slave to ensure every pixel of height is used
                const slave_height = @divTrunc(layout_height, slave_count);
                const slave_height_rem = layout_height % slave_count;

                view.pending_box = Box{
                    .x = @intCast(i32, outer_padding + master_column_width),
                    .y = @intCast(i32, outer_padding + (i - master_count) * slave_height +
                        if (i > master_count) slave_height_rem else 0),

                    .width = slave_column_width,
                    .height = slave_height +
                        if (i == master_count) slave_height_rem else 0,
                };
            }

            i += 1;
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

        const layers = [_]usize{
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
            c.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
            c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
        };

        for (layers) |layer| {
            self.arrangeLayer(self.layers[layer], full_box, &usable_box, true);
        }

        if (self.usable_box.width != usable_box.width or self.usable_box.height != usable_box.height) {
            self.usable_box = usable_box;
            self.root.arrange();
        }

        for (layers) |layer| {
            self.arrangeLayer(self.layers[layer], full_box, &usable_box, false);
        }

        // TODO: handle seat focus
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

            layer_surface.sendConfigure();
        }
    }

    /// Called when the output is destroyed. Evacuate all views from the output
    /// and then remove it from the list of outputs.
    fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const destroyed_output = @fieldParentPtr(Output, "listen_destroy", listener.?);
        const root = destroyed_output.root;

        Log.Debug.log("Output {} destroyed", .{destroyed_output.wlr_output.name});

        // Use the first output in the list that is not the one being destroyed.
        // If there is no other real output, use the noop output.
        var output_it = root.outputs.first;
        const fallback_output = while (output_it) |output_node| : (output_it = output_node.next) {
            if (&output_node.data != destroyed_output) {
                break &output_node.data;
            }
        } else &root.noop_output;

        // Move all views from the destroyed output to the fallback one
        while (destroyed_output.views.last) |node| {
            const view = &node.view;
            view.sendToOutput(fallback_output);
        }

        // Close all layer surfaces on the destroyed output
        for (destroyed_output.layers) |*layer, layer_idx| {
            while (layer.pop()) |node| {
                const layer_surface = &node.data;
                c.wlr_layer_surface_v1_close(layer_surface.wlr_layer_surface);
                // We need to move the closing layer surface to the noop output
                // since it is not immediately destoryed. This just a request
                // to close which will trigger unmap and destroy events in
                // response, and the LayerSurface needs a valid output to
                // handle them.
                root.noop_output.layers[layer_idx].prepend(node);
                layer_surface.output = &root.noop_output;
            }
        }

        // If any seat has the destroyed output focused, focus the fallback one
        var seat_it = root.server.input_manager.seats.first;
        while (seat_it) |seat_node| : (seat_it = seat_node.next) {
            const seat = &seat_node.data;
            if (seat.focused_output == destroyed_output) {
                seat.focused_output = fallback_output;
                seat.focus(null);
            }
        }

        // Remove all listeners
        c.wl_list_remove(&destroyed_output.listen_destroy.link);
        c.wl_list_remove(&destroyed_output.listen_frame.link);
        c.wl_list_remove(&destroyed_output.listen_mode.link);

        // Clean up the wlr_output
        destroyed_output.wlr_output.data = null;

        // Remove the destroyed output from the list
        const node = @fieldParentPtr(std.TailQueue(Output).Node, "data", destroyed_output);
        root.outputs.remove(node);
        root.server.allocator.destroy(node);

        // Arrange the root in case evacuated views affect the layout
        root.arrange();
    }

    fn handleFrame(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This function is called every time an output is ready to display a frame,
        // generally at the output's refresh rate (e.g. 60Hz).
        const output = @fieldParentPtr(Output, "listen_frame", listener.?);
        render.renderOutput(output);
    }

    fn handleMode(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const output = @fieldParentPtr(Output, "listen_mode", listener.?);
        output.arrangeLayers();
        output.root.arrange();
    }
};
