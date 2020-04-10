const std = @import("std");
const c = @import("c.zig");
const render = @import("render.zig");

const Box = @import("box.zig").Box;
const LayerSurface = @import("layer_surface.zig").LayerSurface;
const Root = @import("root.zig").Root;

pub const Output = struct {
    const Self = @This();

    root: *Root,
    wlr_output: *c.wlr_output,

    layers: [4]std.TailQueue(LayerSurface),

    listen_frame: c.wl_listener,

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

        for (self.layers) |*layer| {
            layer.* = std.TailQueue(LayerSurface).init();
        }

        // Sets up a listener for the frame notify event.
        self.listen_frame.notify = handleFrame;
        c.wl_signal_add(&wlr_output.events.frame, &self.listen_frame);

        // Add the new output to the layout. The add_auto function arranges outputs
        // from left-to-right in the order they appear. A more sophisticated
        // compositor would let the user configure the arrangement of outputs in the
        // layout.
        c.wlr_output_layout_add_auto(root.wlr_output_layout, wlr_output);

        // Creating the global adds a wl_output global to the display, which Wayland
        // clients can see to find out information about the output (such as
        // DPI, scale factor, manufacturer, etc).
        c.wlr_output_create_global(wlr_output);
    }

    /// Add a newly created layer surface to the output.
    pub fn addLayerSurface(self: *Self, wlr_layer_surface: *c.wlr_layer_surface_v1) !void {
        const layer = wlr_layer_surface.client_pending.layer;
        const node = try self.layers[@intCast(usize, @enumToInt(layer))].allocateNode(self.root.server.allocator);
        node.data.init(self, wlr_layer_surface, layer);
        self.layers[@intCast(usize, @enumToInt(layer))].append(node);
        self.arrangeLayers();
    }

    /// Arrange all layer surfaces of this output and addjust the usable aread
    pub fn arrangeLayers(self: *Self) void {
        // TODO: handle exclusive zones
        const bounds = blk: {
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

        for (self.layers) |layer| {
            self.arrangeLayer(layer, bounds);
        }

        // TODO: handle seat focus
    }

    /// Arrange the layer surfaces of a given layer
    fn arrangeLayer(self: *Self, layer: std.TailQueue(LayerSurface), bounds: Box) void {
        var it = layer.first;
        while (it) |node| : (it = node.next) {
            const layer_surface = &node.data;
            const current_state = layer_surface.wlr_layer_surface.current;

            var new_box: Box = undefined;

            // Horizontal alignment
            if (current_state.anchor & (@intCast(u32, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT) |
                @intCast(u32, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT)) != 0 and
                current_state.desired_width == 0)
            {
                new_box.x = bounds.x + @intCast(i32, current_state.margin.left);
                new_box.width = bounds.width -
                    (current_state.margin.left + current_state.margin.right);
            } else if (current_state.anchor & @intCast(u32, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT) != 0) {
                new_box.x = bounds.x + @intCast(i32, current_state.margin.left);
                new_box.width = current_state.desired_width;
            } else if (current_state.anchor & @intCast(u32, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT) != 0) {
                new_box.x = bounds.x + @intCast(i32, bounds.width - current_state.desired_width -
                    current_state.margin.right);
                new_box.width = current_state.desired_width;
            } else {
                new_box.x = bounds.x + @intCast(i32, bounds.width / 2 - current_state.desired_width / 2);
                new_box.width = current_state.desired_width;
            }

            // Vertical alignment
            if (current_state.anchor & (@intCast(u32, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP) |
                @intCast(u32, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM)) != 0 and
                current_state.desired_height == 0)
            {
                new_box.y = bounds.y + @intCast(i32, current_state.margin.top);
                new_box.height = bounds.height -
                    (current_state.margin.top + current_state.margin.bottom);
            } else if (current_state.anchor & @intCast(u32, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP) != 0) {
                new_box.y = bounds.y + @intCast(i32, current_state.margin.top);
                new_box.height = current_state.desired_height;
            } else if (current_state.anchor & @intCast(u32, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM) != 0) {
                new_box.y = bounds.y + @intCast(i32, bounds.height - current_state.desired_height -
                    current_state.margin.bottom);
                new_box.height = current_state.desired_height;
            } else {
                new_box.y = bounds.y + @intCast(i32, bounds.height / 2 - current_state.desired_height / 2);
                new_box.height = current_state.desired_height;
            }

            layer_surface.box = new_box;
            layer_surface.sendConfigure();
        }
    }

    fn handleFrame(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This function is called every time an output is ready to display a frame,
        // generally at the output's refresh rate (e.g. 60Hz).
        const output = @fieldParentPtr(Output, "listen_frame", listener.?);
        render.renderOutput(output);
    }
};
