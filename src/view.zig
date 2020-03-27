const std = @import("std");
const c = @import("c.zig").c;

const Root = @import("root.zig").Root;

pub const ViewState = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const View = struct {
    const Self = @This();

    root: *Root,
    wlr_xdg_surface: *c.wlr_xdg_surface,

    mapped: bool,

    current_state: ViewState,
    // TODO: make this a ?ViewState
    pending_state: ViewState,

    pending_serial: ?u32,

    // This is what we render while a transaction is in progress
    stashed_buffer: ?*c.wlr_buffer,

    listen_map: c.wl_listener,
    listen_unmap: c.wl_listener,
    listen_destroy: c.wl_listener,
    listen_commit: c.wl_listener,
    // listen_request_move: c.wl_listener,
    // listen_request_resize: c.wl_listener,

    pub fn init(self: *Self, root: *Root, wlr_xdg_surface: *c.wlr_xdg_surface) void {
        self.root = root;
        self.wlr_xdg_surface = wlr_xdg_surface;

        self.mapped = false;
        self.current_state = ViewState{
            .x = 0,
            .y = 0,
            .height = 0,
            .width = 0,
        };
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

    pub fn needsConfigure(self: *const Self) bool {
        return self.pending_state.width != self.current_state.width or
            self.pending_state.height != self.current_state.height;
    }

    pub fn configurePending(self: *Self) void {
        self.pending_serial = c.wlr_xdg_toplevel_set_size(
            self.wlr_xdg_surface,
            self.pending_state.width,
            self.pending_state.height,
        );
    }

    pub fn sendFrameDone(self: *Self) void {
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

    fn handleMap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // Called when the surface is mapped, or ready to display on-screen.
        const view = @fieldParentPtr(View, "listen_map", listener.?);
        view.mapped = true;

        view.focus(view.wlr_xdg_surface.surface);

        const node = @fieldParentPtr(std.TailQueue(View).Node, "data", view);
        view.root.unmapped_views.remove(node);
        view.root.views.append(node);

        view.root.arrange();
    }

    fn handleUnmap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const view = @fieldParentPtr(View, "listen_unmap", listener.?);
        const root = view.root;
        view.mapped = false;

        if (root.focused_view) |current_focus| {
            // If the view being unmapped is focused
            if (current_focus == view) {
                // If there are more views
                if (root.views.len > 1) {
                    // Focus the next view.
                    root.focusNextView();
                } else {
                    // Otherwise clear the focus
                    root.focused_view = null;
                    _ = c.wlr_xdg_toplevel_set_activated(view.wlr_xdg_surface, false);
                }
            }
        }

        const node = @fieldParentPtr(std.TailQueue(View).Node, "data", view);
        root.views.remove(node);
        root.unmapped_views.append(node);

        root.arrange();
    }

    fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const view = @fieldParentPtr(View, "listen_destroy", listener.?);
        const root = view.root;

        const node = @fieldParentPtr(std.TailQueue(View).Node, "data", view);
        root.unmapped_views.remove(node);
        root.unmapped_views.destroyNode(node, root.server.allocator);
    }

    fn handleCommit(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const view = @fieldParentPtr(View, "listen_commit", listener.?);
        if (view.pending_serial) |s| {
            if (s == view.wlr_xdg_surface.configure_serial) {
                view.root.notifyConfigured();
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
        const root = self.root;
        const wlr_seat = root.server.seat.wlr_seat;
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

    fn isAt(self: *Self, lx: f64, ly: f64, surface: *?*c.wlr_surface, sx: *f64, sy: *f64) bool {
        // XDG toplevels may have nested surfaces, such as popup windows for context
        // menus or tooltips. This function tests if any of those are underneath the
        // coordinates lx and ly (in output Layout Coordinates). If so, it sets the
        // surface pointer to that wlr_surface and the sx and sy coordinates to the
        // coordinates relative to that surface's top-left corner.
        const view_sx = lx - @intToFloat(f64, self.current_state.x);
        const view_sy = ly - @intToFloat(f64, self.current_state.y);

        // This variable seems to have been unsued in TinyWL
        // struct wlr_surface_state *state = &view->xdg_surface->surface->current;

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
