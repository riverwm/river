const std = @import("std");
const c = @import("c.zig");

const Box = @import("box.zig").Box;
const Log = @import("log.zig").Log;
const Output = @import("output.zig").Output;
const Root = @import("root.zig").Root;
const ViewStack = @import("view_stack.zig").ViewStack;

pub const View = struct {
    const Self = @This();

    output: *Output,
    wlr_xdg_surface: *c.wlr_xdg_surface,

    mapped: bool,

    /// If the view is floating or not
    floating: bool,

    /// True if the view is currentlt focused by at lease one seat
    focused: bool,

    current_box: Box,
    pending_box: ?Box,

    /// The dimensions the view would have taken if we didn't force it to tile
    natural_width: u32,
    natural_height: u32,

    current_tags: u32,
    pending_tags: ?u32,

    pending_serial: ?u32,

    // This is what we render while a transaction is in progress
    stashed_buffer: ?*c.wlr_buffer,

    // Listeners that are always active over the view's lifetime
    listen_destroy: c.wl_listener,
    listen_map: c.wl_listener,
    listen_unmap: c.wl_listener,

    // Listeners that are only active while the view is mapped
    listen_commit: c.wl_listener,

    pub fn init(self: *Self, output: *Output, wlr_xdg_surface: *c.wlr_xdg_surface, tags: u32) void {
        self.output = output;
        self.wlr_xdg_surface = wlr_xdg_surface;

        // Inform the xdg toplevel that it is tiled.
        // For example this prevents firefox from drawing shadows around itself
        _ = c.wlr_xdg_toplevel_set_tiled(self.wlr_xdg_surface, c.WLR_EDGE_LEFT |
            c.WLR_EDGE_RIGHT | c.WLR_EDGE_TOP | c.WLR_EDGE_BOTTOM);

        self.mapped = false;

        self.focused = false;

        self.current_box = Box{
            .x = 0,
            .y = 0,
            .height = 0,
            .width = 0,
        };
        self.pending_box = null;

        self.current_tags = tags;
        self.pending_tags = null;

        self.pending_serial = null;

        self.stashed_buffer = null;

        // Add listeners that are active over the view's entire lifetime
        self.listen_destroy.notify = handleDestroy;
        c.wl_signal_add(&self.wlr_xdg_surface.events.destroy, &self.listen_destroy);

        self.listen_map.notify = handleMap;
        c.wl_signal_add(&self.wlr_xdg_surface.events.map, &self.listen_map);

        self.listen_unmap.notify = handleUnmap;
        c.wl_signal_add(&self.wlr_xdg_surface.events.unmap, &self.listen_unmap);
    }

    pub fn deinit(self: *Self) void {
        if (self.stashed_buffer) |buffer| {
            c.wlr_buffer_unref(buffer);
        }
    }

    pub fn needsConfigure(self: Self) bool {
        if (self.pending_box) |pending_box| {
            return pending_box.width != self.current_box.width or
                pending_box.height != self.current_box.height;
        } else {
            return false;
        }
    }

    pub fn configurePending(self: *Self) void {
        if (self.pending_box) |pending_box| {
            const border_width = self.output.root.server.config.border_width;
            const view_padding = self.output.root.server.config.view_padding;
            self.pending_serial = c.wlr_xdg_toplevel_set_size(
                self.wlr_xdg_surface,
                pending_box.width - border_width * 2 - view_padding * 2,
                pending_box.height - border_width * 2 - view_padding * 2,
            );
        } else {
            // TODO: log warning
        }
    }

    pub fn sendFrameDone(self: Self) void {
        var now: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &now);
        c.wlr_surface_send_frame_done(self.wlr_xdg_surface.surface, &now);
    }

    pub fn dropStashedBuffer(self: *Self) void {
        // TODO: log debug error
        if (self.stashed_buffer) |buffer| {
            c.wlr_buffer_unref(buffer);
            self.stashed_buffer = null;
        }
    }

    pub fn stashBuffer(self: *Self) void {
        // TODO: log debug error if there is already a saved buffer
        const wlr_surface = self.wlr_xdg_surface.surface;
        if (c.wlr_surface_has_buffer(wlr_surface)) {
            _ = c.wlr_buffer_ref(wlr_surface.*.buffer);
            self.stashed_buffer = wlr_surface.*.buffer;
        }
    }

    /// Set the focued bool and the active state of the view if it is a toplevel
    pub fn setFocused(self: *Self, focused: bool) void {
        self.focused = focused;
        if (self.wlr_xdg_surface.role ==
            c.enum_wlr_xdg_surface_role.WLR_XDG_SURFACE_ROLE_TOPLEVEL)
        {
            _ = c.wlr_xdg_toplevel_set_activated(self.wlr_xdg_surface, focused);
        }
    }

    /// If true is passsed, make the view float. If false, return it to the tiled
    /// layout.
    pub fn setFloating(self: *Self, float: bool) void {
        if (float and !self.floating) {
            self.floating = true;
            self.pending_box = Box{
                .x = std.math.max(0, @divTrunc(@intCast(i32, self.output.usable_box.width) -
                    @intCast(i32, self.natural_width), 2)),
                .y = std.math.max(0, @divTrunc(@intCast(i32, self.output.usable_box.height) -
                    @intCast(i32, self.natural_height), 2)),
                .width = self.natural_width,
                .height = self.natural_height,
            };
        } else if (!float and self.floating) {
            self.floating = false;
        }
    }

    /// Move a view from one output to another, sending the required enter/leave
    /// events.
    pub fn sendToOutput(self: *Self, destination_output: *Output) void {
        const node = @fieldParentPtr(ViewStack(View).Node, "view", self);

        self.output.views.remove(node);
        destination_output.views.push(node);

        c.wlr_surface_send_leave(self.wlr_xdg_surface.surface, self.output.wlr_output);
        c.wlr_surface_send_enter(self.wlr_xdg_surface.surface, destination_output.wlr_output);

        self.output = destination_output;
    }

    fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const self = @fieldParentPtr(Self, "listen_destroy", listener.?);
        const output = self.output;

        // Remove listeners that are active for the entire lifetime of the view
        c.wl_list_remove(&self.listen_destroy.link);
        c.wl_list_remove(&self.listen_map.link);
        c.wl_list_remove(&self.listen_unmap.link);

        // Remove the view from the stack
        const node = @fieldParentPtr(ViewStack(View).Node, "view", self);
        output.views.remove(node);
        output.root.server.allocator.destroy(node);
    }

    /// Called when the surface is mapped, or ready to display on-screen.
    fn handleMap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const self = @fieldParentPtr(Self, "listen_map", listener.?);
        const root = self.output.root;

        // Add listeners that are only active while mapped
        self.listen_commit.notify = handleCommit;
        c.wl_signal_add(&self.wlr_xdg_surface.surface.*.events.commit, &self.listen_commit);

        self.mapped = true;
        self.floating = false;

        self.natural_width = @intCast(u32, self.wlr_xdg_surface.geometry.width);
        self.natural_height = @intCast(u32, self.wlr_xdg_surface.geometry.height);

        if (self.natural_width == 0 and self.natural_height == 0) {
            self.natural_width = @intCast(u32, self.wlr_xdg_surface.surface.*.current.width);
            self.natural_height = @intCast(u32, self.wlr_xdg_surface.surface.*.current.height);
        }

        const app_id: ?[*:0]const u8 = self.wlr_xdg_surface.unnamed_165.toplevel.*.app_id;
        Log.Debug.log("View with app_id '{}' mapped", .{if (app_id) |id| id else "NULL"});

        // Make views with app_ids listed in the float filter float
        if (app_id) |id| {
            for (self.output.root.server.config.float_filter.items) |filter_app_id| {
                if (std.mem.eql(u8, std.mem.span(id), std.mem.span(filter_app_id))) {
                    self.setFloating(true);
                    break;
                }
            }
        }

        // Focus the newly mapped view. Note: if a seat is focusing a different output
        // it will continue to do so.
        var it = root.server.input_manager.seats.first;
        while (it) |seat_node| : (it = seat_node.next) {
            seat_node.data.focus(self);
        }

        c.wlr_surface_send_enter(self.wlr_xdg_surface.surface, self.output.wlr_output);

        self.output.root.arrange();
    }

    /// Called when the surface is unmapped and will no longer be displayed.
    fn handleUnmap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const self = @fieldParentPtr(Self, "listen_unmap", listener.?);
        const root = self.output.root;
        self.mapped = false;

        // Inform all seats that the view has been unmapped so they can handle focus
        var it = root.server.input_manager.seats.first;
        while (it) |node| : (it = node.next) {
            const seat = &node.data;
            seat.handleViewUnmap(self);
        }

        root.arrange();

        // Remove listeners that are only active while mapped
        c.wl_list_remove(&self.listen_commit.link);
    }

    fn handleCommit(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const self = @fieldParentPtr(Self, "listen_commit", listener.?);
        if (self.pending_serial) |s| {
            if (s == self.wlr_xdg_surface.configure_serial) {
                self.output.root.notifyConfigured();
                self.pending_serial = null;
            }
        }
        // TODO: check for unexpected change in size and react as needed
    }

    fn isAt(self: Self, lx: f64, ly: f64, surface: *?*c.wlr_surface, sx: *f64, sy: *f64) bool {
        // XDG toplevels may have nested surfaces, such as popup windows for context
        // menus or tooltips. This function tests if any of those are underneath the
        // coordinates lx and ly (in output Layout Coordinates). If so, it sets the
        // surface pointer to that wlr_surface and the sx and sy coordinates to the
        // coordinates relative to that surface's top-left corner.
        const view_sx = lx - @intToFloat(f64, self.current_box.x);
        const view_sy = ly - @intToFloat(f64, self.current_box.y);

        // This variable seems to have been unsued in TinyWL
        // struct wlr_surface_box *state = &view->xdg_surface->surface->current;

        var _sx: f64 = undefined;
        var _sy: f64 = undefined;
        const _surface = c.wlr_xdg_surface_surface_at(self.wlr_xdg_surface, view_sx, view_sy, &_sx, &_sy);

        if (_surface) |surface_at| {
            sx.* = _sx;
            sy.* = _sy;
            surface.* = surface_at;
            return true;
        }

        return false;
    }
};
