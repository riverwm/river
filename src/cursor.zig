const std = @import("std");
const c = @import("c.zig");

const Seat = @import("seat.zig").Seat;
const View = @import("view.zig").View;

const CursorMode = enum {
    Passthrough,
    Move,
    Resize,
};

pub const Cursor = struct {
    const Self = @This();

    seat: *Seat,
    wlr_cursor: *c.wlr_cursor,
    wlr_xcursor_manager: *c.wlr_xcursor_manager,

    mode: CursorMode,
    grabbed_view: ?*View,
    grab_x: f64,
    grab_y: f64,
    grab_width: c_int,
    grab_height: c_int,
    resize_edges: u32,

    listen_axis: c.wl_listener,
    listen_button: c.wl_listener,
    listen_frame: c.wl_listener,
    listen_motion_absolute: c.wl_listener,
    listen_motion: c.wl_listener,
    listen_request_set_cursor: c.wl_listener,

    pub fn init(self: *Self, seat: *Seat) !void {
        self.seat = seat;

        // Creates a wlroots utility for tracking the cursor image shown on screen.
        //
        // TODO: free this, it allocates!
        self.wlr_cursor = c.wlr_cursor_create() orelse
            return error.CantCreateWlrCursor;

        // Creates an xcursor manager, another wlroots utility which loads up
        // Xcursor themes to source cursor images from and makes sure that cursor
        // images are available at all scale factors on the screen (necessary for
        // HiDPI support). We add a cursor theme at scale factor 1 to begin with.
        //
        // TODO: free this, it allocates!
        self.wlr_xcursor_manager = c.wlr_xcursor_manager_create(null, 24) orelse
            return error.CantCreateWlrXCursorManager;

        c.wlr_cursor_attach_output_layout(self.wlr_cursor, seat.input_manager.server.root.wlr_output_layout);
        _ = c.wlr_xcursor_manager_load(self.wlr_xcursor_manager, 1);

        self.mode = CursorMode.Passthrough;
        self.grabbed_view = null;
        self.grab_x = 0.0;
        self.grab_y = 0.0;
        self.grab_width = 0;
        self.grab_height = 0;
        self.resize_edges = 0;

        // wlr_cursor *only* displays an image on screen. It does not move around
        // when the pointer moves. However, we can attach input devices to it, and
        // it will generate aggregate events for all of them. In these events, we
        // can choose how we want to process them, forwarding them to clients and
        // moving the cursor around. See following post for more detail:
        // https://drewdevault.com/2018/07/17/Input-handling-in-wlroots.html
        self.listen_axis.notify = handleAxis;
        c.wl_signal_add(&self.wlr_cursor.events.axis, &self.listen_axis);

        self.listen_button.notify = handleButton;
        c.wl_signal_add(&self.wlr_cursor.events.button, &self.listen_button);

        self.listen_frame.notify = handleFrame;
        c.wl_signal_add(&self.wlr_cursor.events.frame, &self.listen_frame);

        self.listen_motion_absolute.notify = handleMotionAbsolute;
        c.wl_signal_add(&self.wlr_cursor.events.motion_absolute, &self.listen_motion_absolute);

        self.listen_motion.notify = handleMotion;
        c.wl_signal_add(&self.wlr_cursor.events.motion, &self.listen_motion);

        self.listen_request_set_cursor.notify = handleRequestSetCursor;
        c.wl_signal_add(&self.seat.wlr_seat.events.request_set_cursor, &self.listen_request_set_cursor);
    }

    pub fn deinit(self: *Self) void {
        c.wlr_xcursor_manager_destroy(self.wlr_xcursor_manager);
        c.wlr_cursor_destroy(self.wlr_cursor);
    }

    fn handleAxis(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is forwarded by the cursor when a pointer emits an axis event,
        // for example when you move the scroll wheel.
        const cursor = @fieldParentPtr(Cursor, "listen_axis", listener.?);
        const event = @ptrCast(
            *c.wlr_event_pointer_axis,
            @alignCast(@alignOf(*c.wlr_event_pointer_axis), data),
        );

        // Notify the client with pointer focus of the axis event.
        c.wlr_seat_pointer_notify_axis(
            cursor.seat.wlr_seat,
            event.time_msec,
            event.orientation,
            event.delta,
            event.delta_discrete,
            event.source,
        );
    }

    fn handleButton(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is forwarded by the cursor when a pointer emits a button
        // event.
        const cursor = @fieldParentPtr(Cursor, "listen_button", listener.?);
        const event = @ptrCast(
            *c.wlr_event_pointer_button,
            @alignCast(@alignOf(*c.wlr_event_pointer_button), data),
        );
        // Notify the client with pointer focus that a button press has occurred
        _ = c.wlr_seat_pointer_notify_button(
            cursor.seat.wlr_seat,
            event.time_msec,
            event.button,
            event.state,
        );

        var sx: f64 = undefined;
        var sy: f64 = undefined;

        var surface: ?*c.wlr_surface = null;
        const view = cursor.seat.input_manager.server.root.viewAt(
            cursor.wlr_cursor.x,
            cursor.wlr_cursor.y,
            &surface,
            &sx,
            &sy,
        );

        if (event.state == c.enum_wlr_button_state.WLR_BUTTON_RELEASED) {
            // If you released any buttons, we exit interactive move/resize mode.
            cursor.mode = CursorMode.Passthrough;
        } else {
            // Focus that client if the button was _pressed_
            if (view) |v| {
                cursor.seat.focus(v);
            }
        }
    }

    fn handleFrame(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is forwarded by the cursor when a pointer emits an frame
        // event. Frame events are sent after regular pointer events to group
        // multiple events together. For instance, two axis events may happen at the
        // same time, in which case a frame event won't be sent in between.
        const cursor = @fieldParentPtr(Cursor, "listen_frame", listener.?);
        // Notify the client with pointer focus of the frame event.
        c.wlr_seat_pointer_notify_frame(cursor.seat.wlr_seat);
    }

    fn processMove(self: Self, time: u32) void {
        // Move the grabbed view to the new position.
        // TODO: log on null
        if (self.grabbed_view) |view| {
            view.current_box.x = @floatToInt(c_int, self.wlr_cursor.x - self.grab_x);
            view.current_box.y = @floatToInt(c_int, self.wlr_cursor.y - self.grab_y);
        }
    }

    fn handleMotionAbsolute(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is forwarded by the cursor when a pointer emits an _absolute_
        // motion event, from 0..1 on each axis. This happens, for example, when
        // wlroots is running under a Wayland window rather than KMS+DRM, and you
        // move the mouse over the window. You could enter the window from any edge,
        // so we have to warp the mouse there. There is also some hardware which
        // emits these events.
        const cursor = @fieldParentPtr(Cursor, "listen_motion_absolute", listener.?);
        const event = @ptrCast(
            *c.wlr_event_pointer_motion_absolute,
            @alignCast(@alignOf(*c.wlr_event_pointer_motion_absolute), data),
        );
        c.wlr_cursor_warp_absolute(cursor.wlr_cursor, event.device, event.x, event.y);
        cursor.processMotion(event.time_msec);
    }

    fn handleMotion(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is forwarded by the cursor when a pointer emits a _relative_
        // pointer motion event (i.e. a delta)
        const cursor = @fieldParentPtr(Cursor, "listen_motion", listener.?);
        const event = @ptrCast(
            *c.wlr_event_pointer_motion,
            @alignCast(@alignOf(*c.wlr_event_pointer_motion), data),
        );
        // The cursor doesn't move unless we tell it to. The cursor automatically
        // handles constraining the motion to the output layout, as well as any
        // special configuration applied for the specific input device which
        // generated the event. You can pass NULL for the device if you want to move
        // the cursor around without any input.
        c.wlr_cursor_move(cursor.wlr_cursor, event.device, event.delta_x, event.delta_y);
        cursor.processMotion(event.time_msec);
    }

    fn handleRequestSetCursor(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is rasied by the seat when a client provides a cursor image
        const cursor = @fieldParentPtr(Cursor, "listen_request_set_cursor", listener.?);
        const event = @ptrCast(
            *c.wlr_seat_pointer_request_set_cursor_event,
            @alignCast(@alignOf(*c.wlr_seat_pointer_request_set_cursor_event), data),
        );
        const focused_client = cursor.seat.wlr_seat.pointer_state.focused_client;

        // This can be sent by any client, so we check to make sure this one is
        // actually has pointer focus first.
        if (focused_client == event.seat_client) {
            // Once we've vetted the client, we can tell the cursor to use the
            // provided surface as the cursor image. It will set the hardware cursor
            // on the output that it's currently on and continue to do so as the
            // cursor moves between outputs.
            c.wlr_cursor_set_surface(
                cursor.wlr_cursor,
                event.surface,
                event.hotspot_x,
                event.hotspot_y,
            );
        }
    }

    fn processsResize(self: Self, time: u32) void {
        // Resizing the grabbed view can be a little bit complicated, because we
        // could be resizing from any corner or edge. This not only resizes the view
        // on one or two axes, but can also move the view if you resize from the top
        // or left edges (or top-left corner).
        //
        // Note that I took some shortcuts here. In a more fleshed-out compositor,
        // you'd wait for the client to prepare a buffer at the new size, then
        // commit any movement that was prepared.

        // TODO: Handle null view
        const view = self.grabbed_view.?;

        const dx: f64 = self.wlr_cursor.x - self.grab_x;
        const dy: f64 = self.wlr_cursor.y - self.grab_y;

        var x: f64 = @intToFloat(f64, view.current_box.x);
        var y: f64 = @intToFloat(f64, view.current_box.y);

        var width = @intToFloat(f64, self.grab_width);
        var height = @intToFloat(f64, self.grab_height);

        if (self.resize_edges & @intCast(u32, c.WLR_EDGE_TOP) != 0) {
            y = self.grab_y + dy;
            height -= dy;
            if (height < 1) {
                y += height;
            }
        } else if (self.resize_edges & @intCast(u32, c.WLR_EDGE_BOTTOM) != 0) {
            height += dy;
        }
        if (self.resize_edges & @intCast(u32, c.WLR_EDGE_LEFT) != 0) {
            x = self.grab_x + dx;
            width -= dx;
            if (width < 1) {
                x += width;
            }
        } else if (self.resize_edges & @intCast(u32, c.WLR_EDGE_RIGHT) != 0) {
            width += dx;
        }
        view.current_box.x = @floatToInt(c_int, x);
        view.current_box.y = @floatToInt(c_int, y);
        _ = c.wlr_xdg_toplevel_set_size(
            view.wlr_xdg_surface,
            @floatToInt(u32, width),
            @floatToInt(u32, height),
        );
    }

    fn processMotion(self: Self, time: u32) void {
        // If the mode is non-passthrough, delegate to those functions.
        if (self.mode == CursorMode.Move) {
            self.processMove(time);
            return;
        } else if (self.mode == CursorMode.Resize) {
            self.processsResize(time);
            return;
        }

        // Otherwise, find the view under the pointer and send the event along.
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        var opt_surface: ?*c.wlr_surface = null;
        const view = self.seat.input_manager.server.root.viewAt(
            self.wlr_cursor.x,
            self.wlr_cursor.y,
            &opt_surface,
            &sx,
            &sy,
        );

        if (view == null) {
            // If there's no view under the cursor, set the cursor image to a
            // default. This is what makes the cursor image appear when you move it
            // around the screen, not over any views.
            c.wlr_xcursor_manager_set_cursor_image(
                self.wlr_xcursor_manager,
                "left_ptr",
                self.wlr_cursor,
            );
        }

        const wlr_seat = self.seat.wlr_seat;
        if (opt_surface) |surface| {
            const focus_changed = wlr_seat.pointer_state.focused_surface != surface;
            // "Enter" the surface if necessary. This lets the client know that the
            // cursor has entered one of its surfaces.
            //
            // Note that this gives the surface "pointer focus", which is distinct
            // from keyboard focus. You get pointer focus by moving the pointer over
            // a window.
            c.wlr_seat_pointer_notify_enter(wlr_seat, surface, sx, sy);
            if (!focus_changed) {
                // The enter event contains coordinates, so we only need to notify
                //on motion if the focus did not change.
                c.wlr_seat_pointer_notify_motion(wlr_seat, time, sx, sy);
            }
        } else {
            // Clear pointer focus so future button events and such are not sent to
            // the last client to have the cursor over it.
            c.wlr_seat_pointer_clear_focus(wlr_seat);
        }
    }
};
