const std = @import("std");
const c = @import("c.zig");

const Box = @import("box.zig").Box;
const Log = @import("log.zig").Log;
const Output = @import("output.zig").Output;

pub const LayerSurface = struct {
    const Self = @This();

    output: *Output,
    wlr_layer_surface: *c.wlr_layer_surface_v1,

    box: Box,
    layer: c.zwlr_layer_shell_v1_layer,

    listen_map: c.wl_listener,
    listen_unmap: c.wl_listener,
    listen_destroy: c.wl_listener,
    listen_commit: c.wl_listener,
    listen_new_popup: c.wl_listener,

    pub fn init(
        self: *Self,
        output: *Output,
        wlr_layer_surface: *c.wlr_layer_surface_v1,
        layer: c.zwlr_layer_shell_v1_layer,
    ) void {
        self.output = output;
        self.wlr_layer_surface = wlr_layer_surface;

        self.box = undefined;
        self.layer = layer;

        self.listen_map.notify = handleMap;
        c.wl_signal_add(&self.wlr_layer_surface.events.map, &self.listen_map);

        self.listen_unmap.notify = handleUnmap;
        c.wl_signal_add(&self.wlr_layer_surface.events.unmap, &self.listen_unmap);

        self.listen_destroy.notify = handleDestroy;
        c.wl_signal_add(&self.wlr_layer_surface.events.destroy, &self.listen_destroy);

        self.listen_commit.notify = handleCommit;
        c.wl_signal_add(&self.wlr_layer_surface.surface.*.events.commit, &self.listen_commit);

        self.listen_new_popup.notify = handleNewPopup;
        c.wl_signal_add(&self.wlr_layer_surface.events.new_popup, &self.listen_new_popup);
    }

    /// Send a configure event to the client with the dimensions of the current box
    pub fn sendConfigure(self: Self) void {
        c.wlr_layer_surface_v1_configure(self.wlr_layer_surface, self.box.width, self.box.height);
    }

    fn handleMap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const layer_surface = @fieldParentPtr(LayerSurface, "listen_map", listener.?);
        c.wlr_surface_send_enter(
            layer_surface.wlr_layer_surface.surface,
            layer_surface.wlr_layer_surface.output,
        );
        layer_surface.output.arrangeLayers();
    }

    fn handleUnmap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const layer_surface = @fieldParentPtr(LayerSurface, "listen_unmap", listener.?);
    }

    fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const layer_surface = @fieldParentPtr(LayerSurface, "listen_destroy", listener.?);
        Log.Debug.log("Layer surface '{}' destroyed", .{layer_surface.wlr_layer_surface.namespace});

        const node = @fieldParentPtr(std.TailQueue(LayerSurface).Node, "data", layer_surface);
        layer_surface.output.layers[@intCast(usize, @enumToInt(layer_surface.layer))].remove(node);
        layer_surface.output.root.server.allocator.destroy(node);

        layer_surface.output.arrangeLayers();
    }

    fn handleCommit(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const layer_surface = @fieldParentPtr(LayerSurface, "listen_commit", listener.?);
        const wlr_layer_surface = layer_surface.wlr_layer_surface;

        if (layer_surface.wlr_layer_surface.output == null) {
            Log.Error.log("Layer surface committed with null output", .{});
            return;
        }

        // If the layer changed, move the LayerSurface to the proper list
        if (layer_surface.layer != layer_surface.wlr_layer_surface.current.layer) {
            const node = @fieldParentPtr(std.TailQueue(LayerSurface).Node, "data", layer_surface);

            const old_layer_idx = @intCast(usize, @enumToInt(layer_surface.layer));
            layer_surface.output.layers[old_layer_idx].remove(node);

            layer_surface.layer = layer_surface.wlr_layer_surface.current.layer;

            const new_layer_idx = @intCast(usize, @enumToInt(layer_surface.layer));
            layer_surface.output.layers[new_layer_idx].append(node);
        }

        // TODO: only reconfigure if things haven't changed
        // https://github.com/swaywm/wlroots/issues/1079
        layer_surface.output.arrangeLayers();
    }

    fn handleNewPopup(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const layer_surface = @fieldParentPtr(LayerSurface, "listen_new_popup", listener.?);
        Log.Debug.log("new layer surface popup.", .{});
        // TODO: handle popups
        unreachable;
    }
};
