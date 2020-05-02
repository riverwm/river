// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const Self = @This();

const std = @import("std");

const c = @import("c.zig");

const LayerSurface = @import("layer_surface.zig");
const Log = @import("log.zig").Log;
const Output = @import("output.zig");
const Seat = @import("seat.zig");
const View = @import("view.zig");
const ViewStack = @import("view_stack.zig").ViewStack;

const CursorMode = enum {
    Passthrough,
    Move,
    Resize,
};

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
    const cursor = @fieldParentPtr(Self, "listen_axis", listener.?);
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
    const self = @fieldParentPtr(Self, "listen_button", listener.?);
    const event = @ptrCast(
        *c.wlr_event_pointer_button,
        @alignCast(@alignOf(*c.wlr_event_pointer_button), data),
    );
    var sx: f64 = undefined;
    var sy: f64 = undefined;

    if (self.surfaceAt(self.wlr_cursor.x, self.wlr_cursor.y, &sx, &sy)) |wlr_surface| {
        // If the found surface is a keyboard inteactive layer surface,
        // give it keyboard focus.
        if (c.wlr_surface_is_layer_surface(wlr_surface)) {
            const wlr_layer_surface = c.wlr_layer_surface_v1_from_wlr_surface(wlr_surface);
            if (wlr_layer_surface.*.current.keyboard_interactive) {
                const layer_surface = @ptrCast(
                    *LayerSurface,
                    @alignCast(@alignOf(*LayerSurface), wlr_layer_surface.*.data),
                );
                self.seat.setFocusRaw(.{ .layer = layer_surface });
            }
        }

        // If the found surface is an xdg toplevel surface, send keyboard
        // focus to the view.
        if (c.wlr_surface_is_xdg_surface(wlr_surface)) {
            const wlr_xdg_surface = c.wlr_xdg_surface_from_wlr_surface(wlr_surface);
            if (wlr_xdg_surface.*.role == .WLR_XDG_SURFACE_ROLE_TOPLEVEL) {
                const view = @ptrCast(*View, @alignCast(@alignOf(*View), wlr_xdg_surface.*.data));
                self.seat.focus(view);
            }
        }

        _ = c.wlr_seat_pointer_notify_button(
            self.seat.wlr_seat,
            event.time_msec,
            event.button,
            event.state,
        );
    }
}

fn handleFrame(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is forwarded by the cursor when a pointer emits an frame
    // event. Frame events are sent after regular pointer events to group
    // multiple events together. For instance, two axis events may happen at the
    // same time, in which case a frame event won't be sent in between.
    const self = @fieldParentPtr(Self, "listen_frame", listener.?);
    // Notify the client with pointer focus of the frame event.
    c.wlr_seat_pointer_notify_frame(self.seat.wlr_seat);
}

fn handleMotionAbsolute(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is forwarded by the cursor when a pointer emits an _absolute_
    // motion event, from 0..1 on each axis. This happens, for example, when
    // wlroots is running under a Wayland window rather than KMS+DRM, and you
    // move the mouse over the window. You could enter the window from any edge,
    // so we have to warp the mouse there. There is also some hardware which
    // emits these events.
    const self = @fieldParentPtr(Self, "listen_motion_absolute", listener.?);
    const event = @ptrCast(
        *c.wlr_event_pointer_motion_absolute,
        @alignCast(@alignOf(*c.wlr_event_pointer_motion_absolute), data),
    );
    c.wlr_cursor_warp_absolute(self.wlr_cursor, event.device, event.x, event.y);
    self.processMotion(event.time_msec);
}

fn handleMotion(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is forwarded by the cursor when a pointer emits a _relative_
    // pointer motion event (i.e. a delta)
    const self = @fieldParentPtr(Self, "listen_motion", listener.?);
    const event = @ptrCast(
        *c.wlr_event_pointer_motion,
        @alignCast(@alignOf(*c.wlr_event_pointer_motion), data),
    );
    // The cursor doesn't move unless we tell it to. The cursor automatically
    // handles constraining the motion to the output layout, as well as any
    // special configuration applied for the specific input device which
    // generated the event. You can pass NULL for the device if you want to move
    // the cursor around without any input.
    c.wlr_cursor_move(self.wlr_cursor, event.device, event.delta_x, event.delta_y);
    self.processMotion(event.time_msec);
}

fn handleRequestSetCursor(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is rasied by the seat when a client provides a cursor image
    const self = @fieldParentPtr(Self, "listen_request_set_cursor", listener.?);
    const event = @ptrCast(
        *c.wlr_seat_pointer_request_set_cursor_event,
        @alignCast(@alignOf(*c.wlr_seat_pointer_request_set_cursor_event), data),
    );
    const focused_client = self.seat.wlr_seat.pointer_state.focused_client;

    // This can be sent by any client, so we check to make sure this one is
    // actually has pointer focus first.
    if (focused_client == event.seat_client) {
        // Once we've vetted the client, we can tell the cursor to use the
        // provided surface as the cursor image. It will set the hardware cursor
        // on the output that it's currently on and continue to do so as the
        // cursor moves between outputs.
        c.wlr_cursor_set_surface(
            self.wlr_cursor,
            event.surface,
            event.hotspot_x,
            event.hotspot_y,
        );
    }
}

fn processMotion(self: Self, time: u32) void {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    if (self.surfaceAt(self.wlr_cursor.x, self.wlr_cursor.y, &sx, &sy)) |wlr_surface| {
        // "Enter" the surface if necessary. This lets the client know that the
        // cursor has entered one of its surfaces.
        //
        // Note that this gives the surface "pointer focus", which is distinct
        // from keyboard focus. You get pointer focus by moving the pointer over
        // a window.
        if (self.seat.input_manager.inputAllowed(wlr_surface)) {
            const wlr_seat = self.seat.wlr_seat;
            const focus_change = wlr_seat.pointer_state.focused_surface != wlr_surface;
            if (focus_change) {
                Log.Debug.log("Pointer notify enter at ({},{})", .{ sx, sy });
                c.wlr_seat_pointer_notify_enter(wlr_seat, wlr_surface, sx, sy);
            } else {
                // The enter event contains coordinates, so we only need to notify
                // on motion if the focus did not change.
                c.wlr_seat_pointer_notify_motion(wlr_seat, time, sx, sy);
            }
            return;
        }
    }

    // There is either no surface under the cursor or input is disallowed
    // Reset the cursor image to the default
    c.wlr_xcursor_manager_set_cursor_image(
        self.wlr_xcursor_manager,
        "left_ptr",
        self.wlr_cursor,
    );
    // Clear pointer focus so future button events and such are not sent to
    // the last client to have the cursor over it.
    c.wlr_seat_pointer_clear_focus(self.seat.wlr_seat);
}

/// Find the topmost surface under the output layout coordinates lx/ly
/// returns the surface if found and sets the sx/sy parametes to the
/// surface coordinates.
fn surfaceAt(self: Self, lx: f64, ly: f64, sx: *f64, sy: *f64) ?*c.wlr_surface {
    // Find the output to check
    const root = self.seat.input_manager.server.root;
    const wlr_output = c.wlr_output_layout_output_at(root.wlr_output_layout, lx, ly) orelse
        return null;
    const output = @ptrCast(
        *Output,
        @alignCast(@alignOf(*Output), wlr_output.*.data orelse return null),
    );

    // Get output-local coords from the layout coords
    var ox = lx;
    var oy = ly;
    c.wlr_output_layout_output_coords(root.wlr_output_layout, wlr_output, &ox, &oy);

    // Check layers and views from top to bottom
    const layer_idxs = [_]usize{
        c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
        c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
        c.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
        c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
    };

    // Check overlay layer incl. popups
    if (layerSurfaceAt(output.*, output.layers[layer_idxs[0]], ox, oy, sx, sy, false)) |surface| {
        return surface;
    }

    // Check top-background popups only
    for (layer_idxs[1..4]) |layer_idx| {
        if (layerSurfaceAt(output.*, output.layers[layer_idx], ox, oy, sx, sy, true)) |surface| {
            return surface;
        }
    }

    // Check top layer
    if (layerSurfaceAt(output.*, output.layers[layer_idxs[1]], ox, oy, sx, sy, false)) |surface| {
        return surface;
    }

    // Check floating views then normal views
    if (viewSurfaceAt(output.*, ox, oy, sx, sy, true)) |surface| {
        return surface;
    }
    if (viewSurfaceAt(output.*, ox, oy, sx, sy, false)) |surface| {
        return surface;
    }

    // Check the bottom-background layers
    for (layer_idxs[2..4]) |layer_idx| {
        if (layerSurfaceAt(output.*, output.layers[layer_idx], ox, oy, sx, sy, false)) |surface| {
            return surface;
        }
    }

    return null;
}

/// Find the topmost surface on the given layer at ox,oy. Will only check
/// popups if popups_only is true.
fn layerSurfaceAt(
    output: Output,
    layer: std.TailQueue(LayerSurface),
    ox: f64,
    oy: f64,
    sx: *f64,
    sy: *f64,
    popups_only: bool,
) ?*c.wlr_surface {
    var it = layer.first;
    while (it) |node| : (it = node.next) {
        const layer_surface = &node.data;
        const surface = c.wlr_layer_surface_v1_surface_at(
            layer_surface.wlr_layer_surface,
            ox - @intToFloat(f64, layer_surface.box.x),
            oy - @intToFloat(f64, layer_surface.box.y),
            sx,
            sy,
        );
        if (surface) |found| {
            if (!popups_only) {
                return found;
            } else if (c.wlr_surface_is_xdg_surface(found)) {
                const wlr_xdg_surface = c.wlr_xdg_surface_from_wlr_surface(found);
                if (wlr_xdg_surface.*.role == .WLR_XDG_SURFACE_ROLE_POPUP) {
                    return found;
                }
            }
        }
    }
    return null;
}

/// Find the topmost visible view surface (incl. popups) at ox,oy. Will
/// check only floating views if floating is true.
fn viewSurfaceAt(output: Output, ox: f64, oy: f64, sx: *f64, sy: *f64, floating: bool) ?*c.wlr_surface {
    var it = ViewStack(View).iterator(output.views.first, output.current_focused_tags);
    while (it.next()) |node| {
        const view = &node.view;
        if (view.floating != floating) {
            continue;
        }
        const surface = switch (view.impl) {
            .xdg_toplevel => |xdg_toplevel| c.wlr_xdg_surface_surface_at(
                xdg_toplevel.wlr_xdg_surface,
                ox - @intToFloat(f64, view.current_box.x),
                oy - @intToFloat(f64, view.current_box.y),
                sx,
                sy,
            ),
        };
        if (surface) |found| {
            return found;
        }
    }
    return null;
}
