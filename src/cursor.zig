const std = @import("std");
const c = @import("c.zig").c;

const CursorMode = enum {
    Passthrough,
    Move,
    Resize,
};

pub const Cursor = struct {
    seat: *Seat,

    wlr_cursor: *c.wlr_cursor,
    wlr_xcursor_manager: *c.wlr_xcursor_manager,

    listen_motion: c.wl_listener,
    listen_motion_absolute: c.wl_listener,
    listen_button: c.wl_listener,
    listen_axis: c.wl_listener,
    listen_frame: c.wl_listener,

    listen_request_cursor: c.wl_listener,

    cursor_mode: CursorMode,
    grabbed_view: ?*View,
    grab_x: f64,
    grab_y: f64,
    grab_width: c_int,
    grab_height: c_int,
    resize_edges: u32,

    pub fn init(seat: *Seat) !@This() {
        var cursor = @This(){
            .server = seat.server,
            .seat = seat,

            // Creates a wlroots utility for tracking the cursor image shown on screen.
            .wlr_cursor = c.wlr_cursor_create() orelse
                return error.CantCreateWlrCursor,

            // Creates an xcursor manager, another wlroots utility which loads up
            // Xcursor themes to source cursor images from and makes sure that cursor
            // images are available at all scale factors on the screen (necessary for
            // HiDPI support). We add a cursor theme at scale factor 1 to begin with.
            .wlr_xcursor_manager = c.wlr_xcursor_manager_create(null, 24) orelse
                return error.CantCreateWlrXCursorManager,

            .listen_motion = c.wl_listener{
                .link = undefined,
                .notify = @This().handle_motion,
            },
            .listen_motion_absolute = c.wl_listener{
                .link = undefined,
                .notify = @This().handle_motion_absolute,
            },
            .listen_button = c.wl_listener{
                .link = undefined,
                .notify = @This().handle_button,
            },
            .listen_axis = c.wl_listener{
                .link = undefined,
                .notify = @This().handle_axis,
            },
            .listen_frame = c.wl_listener{
                .link = undefined,
                .notify = @This().handle_frame,
            },

            .listen_request_set_cursor = c.wl_listener{
                .link = undefined,
                .notify = @This().handle_request_set_cursor,
            },

            .mode = CursorMode.Passthrough,

            .grabbed_view = null,
            .grab_x = 0.0,
            .grab_y = 0.0,
            .grab_width = 0,
            .grab_height = 0,
            .resize_edges = 0,
        };

        c.wlr_cursor_attach_output_layout(cursor.wlr_cursor, seat.*.server.*.output_layout);
        _ = c.wlr_xcursor_manager_load(server.cursor_mgr, 1);

        // wlr_cursor *only* displays an image on screen. It does not move around
        // when the pointer moves. However, we can attach input devices to it, and
        // it will generate aggregate events for all of them. In these events, we
        // can choose how we want to process them, forwarding them to clients and
        // moving the cursor around. See following post for more detail:
        // https://drewdevault.com/2018/07/17/Input-handling-in-wlroots.html
        c.wl_signal_add(&cursor.wlr_cursor.*.events.motion, &cursor.listen_motion);
        c.wl_signal_add(&cursor.wlr_cursor.*.events.motion_absolute, &cursor.listen_motion_absolute);
        c.wl_signal_add(&cursor.wlr_cursor.*.events.button, &cursor.listen_button);
        c.wl_signal_add(&cursor.wlr_cursor.*.events.axis, &cursor.listen_axis);
        c.wl_signal_add(&cursor.wlr_cursor.*.events.frame, &cursor.listen_frame);

        // This listens for clients requesting a specific cursor image
        c.wl_signal_add(&server.seat.*.events.request_set_cursor, &cursor.listen_request_set_cursor);

        return cursor;
    }

    fn process_cursor_move(server: *Server, time: u32) void {
        // Move the grabbed view to the new position.
        server.*.grabbed_view.?.*.x = @floatToInt(c_int, server.*.cursor.*.x - server.*.grab_x);
        server.*.grabbed_view.?.*.y = @floatToInt(c_int, server.*.cursor.*.y - server.*.grab_y);
    }

    fn process_cursor_resize(server: *Server, time: u32) void {
        // Resizing the grabbed view can be a little bit complicated, because we
        // could be resizing from any corner or edge. This not only resizes the view
        // on one or two axes, but can also move the view if you resize from the top
        // or left edges (or top-left corner).
        //
        // Note that I took some shortcuts here. In a more fleshed-out compositor,
        // you'd wait for the client to prepare a buffer at the new size, then
        // commit any movement that was prepared.
        var view = server.*.grabbed_view;

        var dx: f64 = (server.*.cursor.*.x - server.*.grab_x);
        var dy: f64 = (server.*.cursor.*.y - server.*.grab_y);
        var x: f64 = @intToFloat(f64, view.?.*.x);
        var y: f64 = @intToFloat(f64, view.?.*.y);

        var width = @intToFloat(f64, server.*.grab_width);
        var height = @intToFloat(f64, server.*.grab_height);
        if (server.*.resize_edges & @intCast(u32, c.WLR_EDGE_TOP) != 0) {
            y = server.*.grab_y + dy;
            height -= dy;
            if (height < 1) {
                y += height;
            }
        } else if (server.*.resize_edges & @intCast(u32, c.WLR_EDGE_BOTTOM) != 0) {
            height += dy;
        }
        if (server.*.resize_edges & @intCast(u32, c.WLR_EDGE_LEFT) != 0) {
            x = server.*.grab_x + dx;
            width -= dx;
            if (width < 1) {
                x += width;
            }
        } else if (server.*.resize_edges & @intCast(u32, c.WLR_EDGE_RIGHT) != 0) {
            width += dx;
        }
        view.?.*.x = @floatToInt(c_int, x);
        view.?.*.y = @floatToInt(c_int, y);
        _ = c.wlr_xdg_toplevel_set_size(
            view.?.*.xdg_surface,
            @floatToInt(u32, width),
            @floatToInt(u32, height),
        );
    }

    fn process_cursor_motion(server: *Server, time: u32) void {
        // If the mode is non-passthrough, delegate to those functions.
        if (server.*.cursor_mode == CursorMode.Move) {
            process_cursor_move(server, time);
            return;
        } else if (server.*.cursor_mode == CursorMode.Resize) {
            process_cursor_resize(server, time);
            return;
        }

        // Otherwise, find the view under the pointer and send the event along.
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        var seat = server.*.seat;
        var opt_surface: ?*c.wlr_surface = null;
        var view = desktop_view_at(
            server,
            server.*.cursor.*.x,
            server.*.cursor.*.y,
            &opt_surface,
            &sx,
            &sy,
        );

        if (view == null) {
            // If there's no view under the cursor, set the cursor image to a
            // default. This is what makes the cursor image appear when you move it
            // around the screen, not over any views.
            c.wlr_xcursor_manager_set_cursor_image(
                server.*.cursor_mgr,
                "left_ptr",
                server.*.cursor,
            );
        }

        if (opt_surface) |surface| {
            const focus_changed = seat.*.pointer_state.focused_surface != surface;
            // "Enter" the surface if necessary. This lets the client know that the
            // cursor has entered one of its surfaces.
            //
            // Note that this gives the surface "pointer focus", which is distinct
            // from keyboard focus. You get pointer focus by moving the pointer over
            // a window.
            c.wlr_seat_pointer_notify_enter(seat, surface, sx, sy);
            if (!focus_changed) {
                // The enter event contains coordinates, so we only need to notify
                // on motion if the focus did not change.
                c.wlr_seat_pointer_notify_motion(seat, time, sx, sy);
            }
        } else {
            // Clear pointer focus so future button events and such are not sent to
            // the last client to have the cursor over it.
            c.wlr_seat_pointer_clear_focus(seat);
        }
    }

    fn handle_motion(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is forwarded by the cursor when a pointer emits a _relative_
        // pointer motion event (i.e. a delta)
        var server = @fieldParentPtr(Server, "cursor_motion", listener);
        var event = @ptrCast(
            *c.wlr_event_pointer_motion,
            @alignCast(@alignOf(*c.wlr_event_pointer_motion), data),
        );
        // The cursor doesn't move unless we tell it to. The cursor automatically
        // handles constraining the motion to the output layout, as well as any
        // special configuration applied for the specific input device which
        // generated the event. You can pass NULL for the device if you want to move
        // the cursor around without any input.
        c.wlr_cursor_move(server.*.cursor, event.*.device, event.*.delta_x, event.*.delta_y);
        process_cursor_motion(server, event.*.time_msec);
    }

    fn handle_motion_absolute(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is forwarded by the cursor when a pointer emits an _absolute_
        // motion event, from 0..1 on each axis. This happens, for example, when
        // wlroots is running under a Wayland window rather than KMS+DRM, and you
        // move the mouse over the window. You could enter the window from any edge,
        // so we have to warp the mouse there. There is also some hardware which
        // emits these events.
        var server = @fieldParentPtr(Server, "cursor_motion_absolute", listener);
        var event = @ptrCast(
            *c.wlr_event_pointer_motion_absolute,
            @alignCast(@alignOf(*c.wlr_event_pointer_motion_absolute), data),
        );
        c.wlr_cursor_warp_absolute(server.*.cursor, event.*.device, event.*.x, event.*.y);
        process_cursor_motion(server, event.*.time_msec);
    }

    fn handle_button(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is forwarded by the cursor when a pointer emits a button
        // event.
        var server = @fieldParentPtr(Server, "cursor_button", listener);
        var event = @ptrCast(
            *c.wlr_event_pointer_button,
            @alignCast(@alignOf(*c.wlr_event_pointer_button), data),
        );
        // Notify the client with pointer focus that a button press has occurred
        _ = c.wlr_seat_pointer_notify_button(
            server.*.seat,
            event.*.time_msec,
            event.*.button,
            event.*.state,
        );

        var sx: f64 = undefined;
        var sy: f64 = undefined;

        var surface: ?*c.wlr_surface = null;
        var view = desktop_view_at(
            server,
            server.*.cursor.*.x,
            server.*.cursor.*.y,
            &surface,
            &sx,
            &sy,
        );

        if (event.*.state == c.enum_wlr_button_state.WLR_BUTTON_RELEASED) {
            // If you released any buttons, we exit interactive move/resize mode.
            server.*.cursor_mode = CursorMode.Passthrough;
        } else {
            // Focus that client if the button was _pressed_
            if (view) |v| {
                focus_view(v, surface.?);
            }
        }
    }

    fn handle_axis(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is forwarded by the cursor when a pointer emits an axis event,
        // for example when you move the scroll wheel.
        var server = @fieldParentPtr(Server, "cursor_axis", listener);
        var event = @ptrCast(
            *c.wlr_event_pointer_axis,
            @alignCast(@alignOf(*c.wlr_event_pointer_axis), data),
        );
        // Notify the client with pointer focus of the axis event.
        c.wlr_seat_pointer_notify_axis(
            server.*.seat,
            event.*.time_msec,
            event.*.orientation,
            event.*.delta,
            event.*.delta_discrete,
            event.*.source,
        );
    }

    fn handle_frame(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is forwarded by the cursor when a pointer emits an frame
        // event. Frame events are sent after regular pointer events to group
        // multiple events together. For instance, two axis events may happen at the
        // same time, in which case a frame event won't be sent in between.
        var server = @fieldParentPtr(Server, "cursor_frame", listener);
        // Notify the client with pointer focus of the frame event.
        c.wlr_seat_pointer_notify_frame(server.*.seat);
    }

    fn handle_request_set_cursor(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is rasied by the seat when a client provides a cursor image
        var server = @fieldParentPtr(Server, "request_cursor", listener);
        var event = @ptrCast(
            *c.wlr_seat_pointer_request_set_cursor_event,
            @alignCast(@alignOf(*c.wlr_seat_pointer_request_set_cursor_event), data),
        );
        var focused_client = server.*.seat.*.pointer_state.focused_client;

        // This can be sent by any client, so we check to make sure this one is
        // actually has pointer focus first.
        if (focused_client == event.*.seat_client) {
            // Once we've vetted the client, we can tell the cursor to use the
            // provided surface as the cursor image. It will set the hardware cursor
            // on the output that it's currently on and continue to do so as the
            // cursor moves between outputs.
            c.wlr_cursor_set_surface(
                server.*.cursor,
                event.*.surface,
                event.*.hotspot_x,
                event.*.hotspot_y,
            );
        }
    }
};
