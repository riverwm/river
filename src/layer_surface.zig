const std = @import("std");
const c = @import("c.zig");

const Box = @import("box.zig").Box;
const Log = @import("log.zig").Log;
const Output = @import("output.zig").Output;

pub const LayerSurface = struct {
    const Self = @This();

    output: *Output,
    wlr_layer_surface: *c.wlr_layer_surface_v1,

    /// True if the layer surface is currently mapped
    mapped: bool,

    box: Box,
    layer: c.zwlr_layer_shell_v1_layer,

    // Listeners active the entire lifetime of the layser surface
    listen_destroy: c.wl_listener,
    listen_map: c.wl_listener,
    listen_unmap: c.wl_listener,

    // Listeners only active while the layer surface is mapped
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

        self.mapped = false;

        self.box = undefined;
        self.layer = layer;

        // Set up listeners that are active for the entire lifetime of the layer surface
        self.listen_destroy.notify = handleDestroy;
        c.wl_signal_add(&self.wlr_layer_surface.events.destroy, &self.listen_destroy);

        self.listen_map.notify = handleMap;
        c.wl_signal_add(&self.wlr_layer_surface.events.map, &self.listen_map);

        self.listen_unmap.notify = handleUnmap;
        c.wl_signal_add(&self.wlr_layer_surface.events.unmap, &self.listen_unmap);
    }

    /// Send a configure event to the client with the dimensions of the current box
    pub fn sendConfigure(self: Self) void {
        c.wlr_layer_surface_v1_configure(self.wlr_layer_surface, self.box.width, self.box.height);
    }

    fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const layer_surface = @fieldParentPtr(LayerSurface, "listen_destroy", listener.?);
        const output = layer_surface.output;

        Log.Debug.log("Layer surface '{}' destroyed", .{layer_surface.wlr_layer_surface.namespace});

        // Remove listeners active the entire lifetime of the layer surface
        c.wl_list_remove(&layer_surface.listen_destroy.link);
        c.wl_list_remove(&layer_surface.listen_map.link);
        c.wl_list_remove(&layer_surface.listen_unmap.link);

        const node = @fieldParentPtr(std.TailQueue(LayerSurface).Node, "data", layer_surface);
        output.layers[@intCast(usize, @enumToInt(layer_surface.layer))].remove(node);
        output.root.server.allocator.destroy(node);
    }

    fn handleMap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const layer_surface = @fieldParentPtr(LayerSurface, "listen_map", listener.?);
        const wlr_layer_surface = layer_surface.wlr_layer_surface;

        layer_surface.mapped = true;

        // Add listeners that are only active while mapped
        layer_surface.listen_commit.notify = handleCommit;
        c.wl_signal_add(&wlr_layer_surface.surface.*.events.commit, &layer_surface.listen_commit);

        layer_surface.listen_new_popup.notify = handleNewPopup;
        c.wl_signal_add(&wlr_layer_surface.events.new_popup, &layer_surface.listen_new_popup);

        c.wlr_surface_send_enter(
            wlr_layer_surface.surface,
            wlr_layer_surface.output,
        );

        layer_surface.output.arrangeLayers();
    }

    fn handleUnmap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const layer_surface = @fieldParentPtr(LayerSurface, "listen_unmap", listener.?);

        layer_surface.mapped = false;

        // remove listeners only active while the layer surface is mapped
        c.wl_list_remove(&layer_surface.listen_commit.link);
        c.wl_list_remove(&layer_surface.listen_new_popup.link);

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
