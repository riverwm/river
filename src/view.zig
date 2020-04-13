const std = @import("std");
const c = @import("c.zig");

const Box = @import("box.zig").Box;
const Output = @import("output.zig").Output;
const Root = @import("root.zig").Root;
const ViewStack = @import("view_stack.zig").ViewStack;

pub const View = struct {
    const Self = @This();

    output: *Output,
    wlr_xdg_surface: *c.wlr_xdg_surface,

    mapped: bool,

    current_box: Box,
    pending_box: ?Box,

    current_tags: u32,
    pending_tags: ?u32,

    pending_serial: ?u32,

    // This is what we render while a transaction is in progress
    stashed_buffer: ?*c.wlr_buffer,

    listen_map: c.wl_listener,
    listen_unmap: c.wl_listener,
    listen_destroy: c.wl_listener,
    listen_commit: c.wl_listener,
    // listen_request_move: c.wl_listener,
    // listen_request_resize: c.wl_listener,

    pub fn init(self: *Self, output: *Output, wlr_xdg_surface: *c.wlr_xdg_surface, tags: u32) void {
        self.output = output;
        self.wlr_xdg_surface = wlr_xdg_surface;

        // Inform the xdg toplevel that it is tiled.
        // For example this prevents firefox from drawing shadows around itself
        _ = c.wlr_xdg_toplevel_set_tiled(self.wlr_xdg_surface, c.WLR_EDGE_LEFT |
            c.WLR_EDGE_RIGHT | c.WLR_EDGE_TOP | c.WLR_EDGE_BOTTOM);

        self.mapped = false;

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

        self.listen_map.notify = handleMap;
        c.wl_signal_add(&self.wlr_xdg_surface.events.map, &self.listen_map);

        self.listen_unmap.notify = handleUnmap;
        c.wl_signal_add(&self.wlr_xdg_surface.events.unmap, &self.listen_unmap);

        self.listen_destroy.notify = handleDestroy;
        c.wl_signal_add(&self.wlr_xdg_surface.events.destroy, &self.listen_destroy);

        self.listen_commit.notify = handleCommit;
        c.wl_signal_add(&self.wlr_xdg_surface.surface.*.events.commit, &self.listen_commit);

        // const toplevel = xdg_surface.unnamed_160.toplevel;
        // c.wl_signal_add(&toplevel.events.request_move, &view.request_move);
        // c.wl_signal_add(&toplevel.events.request_resize, &view.request_resize);
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
        var now: c.struct_timespec = undefined;
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

    /// Send a close event to the view's client
    pub fn close(self: Self) void {
        // Note: we don't call arrange() here as it will be called
        // automatically when the view is unmapped.
        c.wlr_xdg_toplevel_send_close(self.wlr_xdg_surface);
    }

    fn handleMap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // Called when the surface is mapped, or ready to display on-screen.
        const view = @fieldParentPtr(View, "listen_map", listener.?);
        view.mapped = true;
        view.focus(view.wlr_xdg_surface.surface);
        view.output.root.arrange();
    }

    fn handleUnmap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const view = @fieldParentPtr(View, "listen_unmap", listener.?);
        const root = view.output.root;
        view.mapped = false;

        if (root.focused_view) |current_focus| {
            // If the view being unmapped is focused
            if (current_focus == view) {
                // Focus the previous view. This clears the focus if there are no visible views.
                // FIXME: must be fixed in next commit adding focus stack
                //root.focusPrevView();
            }
        }

        root.arrange();
    }

    fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const view = @fieldParentPtr(View, "listen_destroy", listener.?);
        const output = view.output;

        const node = @fieldParentPtr(ViewStack(View).Node, "view", view);
        output.views.remove(node);
        output.root.server.allocator.destroy(node);
    }

    fn handleCommit(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const view = @fieldParentPtr(View, "listen_commit", listener.?);
        if (view.pending_serial) |s| {
            if (s == view.wlr_xdg_surface.configure_serial) {
                view.output.root.notifyConfigured();
                view.pending_serial = null;
            }
        }
        // TODO: check for unexpected change in size and react as needed
    }

    // fn xdgToplevelRequestMove(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    //     // ignore for now
    // }

    // fn xdgToplevelRequestResize(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    //     // ignore for now
    // }

    fn focus(self: *Self, surface: *c.wlr_surface) void {
        const root = self.output.root;
        // TODO: remove this hack
        const wlr_seat = root.server.input_manager.seats.first.?.data.wlr_seat;
        const prev_surface = wlr_seat.keyboard_state.focused_surface;

        if (prev_surface == surface) {
            // Don't re-focus an already focused surface.
            // TODO: debug message?
            return;
        }

        root.focused_view = self;

        if (prev_surface != null) {
            // Deactivate the previously focused surface. This lets the client know
            // it no longer has focus and the client will repaint accordingly, e.g.
            // stop displaying a caret.
            const prev_xdg_surface = c.wlr_xdg_surface_from_wlr_surface(prev_surface);
            _ = c.wlr_xdg_toplevel_set_activated(prev_xdg_surface, false);
        }

        // Activate the new surface
        _ = c.wlr_xdg_toplevel_set_activated(self.wlr_xdg_surface, true);

        // Tell the seat to have the keyboard enter this surface. wlroots will keep
        // track of this and automatically send key events to the appropriate
        // clients without additional work on your part.
        const keyboard: *c.wlr_keyboard = c.wlr_seat_get_keyboard(wlr_seat);
        c.wlr_seat_keyboard_notify_enter(
            wlr_seat,
            self.wlr_xdg_surface.surface,
            &keyboard.keycodes,
            keyboard.num_keycodes,
            &keyboard.modifiers,
        );
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
