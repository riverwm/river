const std = @import("std");
const c = @import("c.zig");

const Box = @import("box.zig");
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
        wlr_layer_surface.data = self;

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

    fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const self = @fieldParentPtr(Self, "listen_destroy", listener.?);
        const output = self.output;

        Log.Debug.log("Layer surface '{}' destroyed", .{self.wlr_layer_surface.namespace});

        // Remove listeners active the entire lifetime of the layer surface
        c.wl_list_remove(&self.listen_destroy.link);
        c.wl_list_remove(&self.listen_map.link);
        c.wl_list_remove(&self.listen_unmap.link);

        const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
        output.layers[@intCast(usize, @enumToInt(self.layer))].remove(node);
        output.root.server.allocator.destroy(node);

        self.output.arrangeLayers();
    }

    fn handleMap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const self = @fieldParentPtr(Self, "listen_map", listener.?);
        const wlr_layer_surface = self.wlr_layer_surface;

        Log.Debug.log("Layer surface '{}' mapped.", .{wlr_layer_surface.namespace});

        self.mapped = true;

        // Add listeners that are only active while mapped
        self.listen_commit.notify = handleCommit;
        c.wl_signal_add(&wlr_layer_surface.surface.*.events.commit, &self.listen_commit);

        self.listen_new_popup.notify = handleNewPopup;
        c.wl_signal_add(&wlr_layer_surface.events.new_popup, &self.listen_new_popup);

        c.wlr_surface_send_enter(
            wlr_layer_surface.surface,
            wlr_layer_surface.output,
        );
    }

    fn handleUnmap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const self = @fieldParentPtr(Self, "listen_unmap", listener.?);

        Log.Debug.log("Layer surface '{}' unmapped.", .{self.wlr_layer_surface.namespace});

        self.mapped = false;

        // remove listeners only active while the layer surface is mapped
        c.wl_list_remove(&self.listen_commit.link);
        c.wl_list_remove(&self.listen_new_popup.link);

        // If the unmapped surface is focused, clear focus
        var it = self.output.root.server.input_manager.seats.first;
        while (it) |node| : (it = node.next) {
            const seat = &node.data;
            if (seat.focused_layer) |current_focus| {
                if (current_focus == self) {
                    seat.setFocusRaw(.{ .none = {} });
                }
            }
        }

        // This gives exclusive focus to a keyboard interactive top or overlay layer
        // surface if there is one.
        self.output.arrangeLayers();

        // Ensure that focus is given to the appropriate view if there is no
        // other top/overlay layer surface to grab focus.
        it = self.output.root.server.input_manager.seats.first;
        while (it) |node| : (it = node.next) {
            const seat = &node.data;
            seat.focus(null);
        }
    }

    fn handleCommit(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const self = @fieldParentPtr(Self, "listen_commit", listener.?);
        const wlr_layer_surface = self.wlr_layer_surface;

        if (self.wlr_layer_surface.output == null) {
            Log.Error.log("Layer surface committed with null output", .{});
            return;
        }

        // If the layer changed, move the LayerSurface to the proper list
        if (self.layer != self.wlr_layer_surface.current.layer) {
            const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);

            const old_layer_idx = @intCast(usize, @enumToInt(self.layer));
            self.output.layers[old_layer_idx].remove(node);

            self.layer = self.wlr_layer_surface.current.layer;

            const new_layer_idx = @intCast(usize, @enumToInt(self.layer));
            self.output.layers[new_layer_idx].append(node);
        }

        // TODO: only reconfigure if things haven't changed
        // https://github.com/swaywm/wlroots/issues/1079
        self.output.arrangeLayers();
    }

    fn handleNewPopup(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const self = @fieldParentPtr(Self, "listen_new_popup", listener.?);
        Log.Debug.log("new layer surface popup.", .{});
        // TODO: handle popups
        unreachable;
    }
};
