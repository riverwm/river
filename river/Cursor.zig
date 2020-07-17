// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
// Copyright 2020 Leon Henrik Plickat
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

const build_options = @import("build_options");
const std = @import("std");

const c = @import("c.zig");
const log = @import("log.zig");
const util = @import("util.zig");

const Box = @import("Box.zig");
const Config = @import("Config.zig");
const LayerSurface = @import("LayerSurface.zig");
const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;

const CursorMode = enum {
    Passthrough,
    Move,
    Resize,
};

const default_size = 24;

seat: *Seat,
wlr_cursor: *c.wlr_cursor,
wlr_xcursor_manager: *c.wlr_xcursor_manager,

mode: CursorMode,
grabbed_view: *View,

/// Distance between cursor and top-left corner of grabbed view
grab_delta_x: f64,
grab_delta_y: f64,

/// Dimensions of the output the grabbed view is on
grab_output_width: u64,
grab_output_height: u64,

const CursorPosition = struct {
    x: f64,
    y: f64,
};

listen_axis: c.wl_listener,
listen_button: c.wl_listener,
listen_frame: c.wl_listener,
listen_motion_absolute: c.wl_listener,
listen_motion: c.wl_listener,
listen_request_set_cursor: c.wl_listener,

pub fn init(self: *Self, seat: *Seat) !void {
    self.seat = seat;

    // Creates a wlroots utility for tracking the cursor image shown on screen.
    self.wlr_cursor = c.wlr_cursor_create() orelse return error.OutOfMemory;
    c.wlr_cursor_attach_output_layout(self.wlr_cursor, seat.input_manager.server.root.wlr_output_layout);

    // This is here so that self.wlr_xcursor_manager doesn't need to be an
    // optional pointer. This isn't optimal as it does a needless allocation,
    // but this is not a hot path.
    self.wlr_xcursor_manager = c.wlr_xcursor_manager_create(null, default_size) orelse
        return error.OutOfMemory;
    try self.setTheme(null, null);

    self.mode = CursorMode.Passthrough;
    self.grabbed_view = undefined;
    self.grab_delta_x = 0.0;
    self.grab_delta_y = 0.0;

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

/// Set the cursor theme for the given seat, as well as the xwayland theme if
/// this is the default seat. Either argument may be null, in which case a
/// default will be used.
pub fn setTheme(self: *Self, theme: ?[*:0]const u8, _size: ?u32) !void {
    const server = self.seat.input_manager.server;
    const size = _size orelse default_size;

    c.wlr_xcursor_manager_destroy(self.wlr_xcursor_manager);
    self.wlr_xcursor_manager = c.wlr_xcursor_manager_create(theme, size) orelse
        return error.OutOfMemory;

    // For each output, ensure a theme of the proper scale is loaded
    var it = server.root.outputs.first;
    while (it) |node| : (it = node.next) {
        const wlr_output = node.data.wlr_output;
        if (!c.wlr_xcursor_manager_load(self.wlr_xcursor_manager, wlr_output.scale))
            log.err(.cursor, "failed to load xcursor theme '{}' at scale {}", .{ theme, wlr_output.scale });
    }

    // If this cursor belongs to the default seat, set the xcursor environment
    // variables and the xwayland cursor theme.
    if (self.seat == self.seat.input_manager.default_seat) {
        const size_str = try std.fmt.allocPrint0(util.gpa, "{}", .{size});
        defer util.gpa.free(size_str);
        if (c.setenv("XCURSOR_SIZE", size_str, 1) < 0) return error.OutOfMemory;
        if (theme) |t| if (c.setenv("XCURSOR_THEME", t, 1) < 0) return error.OutOfMemory;

        if (build_options.xwayland) {
            if (c.wlr_xcursor_manager_load(self.wlr_xcursor_manager, 1)) {
                const wlr_xcursor = c.wlr_xcursor_manager_get_xcursor(self.wlr_xcursor_manager, "left_ptr", 1).?;
                const image: *c.wlr_xcursor_image = wlr_xcursor.*.images[0];
                c.wlr_xwayland_set_cursor(
                    server.wlr_xwayland,
                    image.buffer,
                    image.width * 4,
                    image.width,
                    image.height,
                    @intCast(i32, image.hotspot_x),
                    @intCast(i32, image.hotspot_y),
                );
            } else log.err(.cursor, "failed to load xcursor theme '{}' at scale 1", .{theme});
        }
    }
}

fn handleAxis(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is forwarded by the cursor when a pointer emits an axis event,
    // for example when you move the scroll wheel.
    const cursor = @fieldParentPtr(Self, "listen_axis", listener.?);
    const event = util.voidCast(c.wlr_event_pointer_axis, data.?);

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

fn enterCursorMode(self: *Self, event: *c.wlr_event_pointer_button, view: *View, mode: CursorMode) void {
    if (self.mode != CursorMode.Passthrough) return;

    switch (mode) {
        .Passthrough => {},
        .Resize => {},

        .Move => {
            self.grabbed_view = view;

            // Automatically float alll views being moved by the pointer
            if (!self.grabbed_view.current.float) {
                self.grabbed_view.pending.float = true;
                // Start a transaction to apply the pending state of the grabbed
                // view and rearrange the layout to fill the hole.
                self.grabbed_view.output.root.arrange();
            }

            // Enter moving mode
            self.mode = CursorMode.Move;

            self.grab_delta_x = @fabs(self.wlr_cursor.x - @intToFloat(f64, self.grabbed_view.pending.box.x));
            self.grab_delta_y = @fabs(self.wlr_cursor.y - @intToFloat(f64, self.grabbed_view.pending.box.y));

            // Clear cursor focus, so that the surface does not receive events
            c.wlr_seat_pointer_clear_focus(self.seat.wlr_seat);

            c.wlr_xcursor_manager_set_cursor_image(self.wlr_xcursor_manager, "move", self.wlr_cursor);

            // Get dimension of output the grabbed view is on
            var output_width_c: c_int = undefined;
            var output_height_c: c_int = undefined;
            c.wlr_output_effective_resolution(
                self.grabbed_view.output.wlr_output,
                &output_width_c,
                &output_height_c,
            );
            self.grab_output_width = @intCast(u64, output_width_c);
            self.grab_output_height = @intCast(u64, output_height_c);
        },
    }
}

fn leaveCursorMode(self: *Self, event: *c.wlr_event_pointer_button) void {
    switch (self.mode) {
        .Passthrough => {},
        .Resize => {},

        .Move => {
            self.mode = CursorMode.Passthrough;

            // Set generic cursor image in case the application does not set one.
            c.wlr_xcursor_manager_set_cursor_image(
                self.wlr_xcursor_manager,
                "left_ptr",
                self.wlr_cursor,
            );

            // Cursor-Reentry by notifying surface underneath cursor.
            processMotionPassthrough(self, event.time_msec);
        },
    }
}

fn handleButton(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is forwarded by the cursor when a pointer emits a button
    // event.
    const self = @fieldParentPtr(Self, "listen_button", listener.?);
    const event = util.voidCast(c.wlr_event_pointer_button, data.?);
    var sx: f64 = undefined;
    var sy: f64 = undefined;

    if (self.surfaceAt(self.wlr_cursor.x, self.wlr_cursor.y, &sx, &sy)) |wlr_surface| {
        // If the found surface is a keyboard inteactive layer surface,
        // give it keyboard focus.
        if (c.wlr_surface_is_layer_surface(wlr_surface)) {
            const wlr_layer_surface = c.wlr_layer_surface_v1_from_wlr_surface(wlr_surface);
            if (wlr_layer_surface.*.current.keyboard_interactive) {
                const layer_surface = util.voidCast(LayerSurface, wlr_layer_surface.*.data.?);
                self.seat.setFocusRaw(.{ .layer = layer_surface });
            }
        }

        // If the found surface is an xdg toplevel surface, send keyboard
        // focus to the view.
        if (c.wlr_surface_is_xdg_surface(wlr_surface)) {
            const wlr_xdg_surface = c.wlr_xdg_surface_from_wlr_surface(wlr_surface);
            if (wlr_xdg_surface.*.role == .WLR_XDG_SURFACE_ROLE_TOPLEVEL) {
                const view = util.voidCast(View, wlr_xdg_surface.*.data.?);
                self.seat.focus(view);

                if (event.state == .WLR_BUTTON_PRESSED) {
                    // If the button is pressed and the pointer modifier is
                    // active, enter cursor mode or close view and return.
                    if (self.seat.pointer_modifier) {
                        switch (event.button) {
                            c.BTN_LEFT => enterCursorMode(self, event, view, CursorMode.Move),
                            c.BTN_MIDDLE => view.close(),
                            c.BTN_RIGHT => {}, // TODO Resize

                            // TODO Some mice have additional buttons. These
                            // could also be bound to some useful action.
                            else => {},
                        }
                        return;
                    }
                } else if (self.mode != CursorMode.Passthrough) {
                    // If the button is released and the current cursor mode is
                    // not passthrough, leave cursor mode and return.
                    leaveCursorMode(self, event);
                    return;
                }
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
    const event = util.voidCast(c.wlr_event_pointer_motion_absolute, data.?);
    switch (self.mode) {
        CursorMode.Passthrough => {
            c.wlr_cursor_warp_absolute(self.wlr_cursor, event.device, event.x, event.y);
            processMotionPassthrough(self, event.time_msec);
        },
        CursorMode.Move => {
            var x_layout: f64 = undefined;
            var y_layout: f64 = undefined;
            c.wlr_cursor_absolute_to_layout_coords(self.wlr_cursor, event.device, event.x, event.y, &x_layout, &y_layout);
            var cursor: CursorPosition = processMotionMove(self, x_layout, y_layout);
            _ = c.wlr_cursor_warp(self.wlr_cursor, event.device, cursor.x, cursor.y);
        },
        CursorMode.Resize => {},
    }
}

fn handleMotion(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is forwarded by the cursor when a pointer emits a _relative_
    // pointer motion event (i.e. a delta)
    const self = @fieldParentPtr(Self, "listen_motion", listener.?);
    const event = util.voidCast(c.wlr_event_pointer_motion, data.?);
    switch (self.mode) {
        CursorMode.Passthrough => {
            // The cursor doesn't move unless we tell it to. The cursor automatically
            // handles constraining the motion to the output layout, as well as any
            // special configuration applied for the specific input device which
            // generated the event. You can pass NULL for the device if you want to move
            // the cursor around without any input.
            c.wlr_cursor_move(self.wlr_cursor, event.device, event.delta_x, event.delta_y);
            processMotionPassthrough(self, event.time_msec);
        },
        CursorMode.Move => {
            var cursor: CursorPosition = processMotionMove(self, event.delta_x + self.wlr_cursor.x, event.delta_y + self.wlr_cursor.y);
            _ = c.wlr_cursor_warp(self.wlr_cursor, event.device, cursor.x, cursor.y);
        },
        CursorMode.Resize => {},
    }
}

fn handleRequestSetCursor(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is rasied by the seat when a client provides a cursor image
    const self = @fieldParentPtr(Self, "listen_request_set_cursor", listener.?);
    const event = util.voidCast(c.wlr_seat_pointer_request_set_cursor_event, data.?);
    const focused_client = self.seat.wlr_seat.pointer_state.focused_client;

    // This can be sent by any client, so we check to make sure this one is
    // actually has pointer focus first.
    if (focused_client == event.seat_client) {
        // Once we've vetted the client, we can tell the cursor to use the
        // provided surface as the cursor image. It will set the hardware cursor
        // on the output that it's currently on and continue to do so as the
        // cursor moves between outputs.
        log.debug(.cursor, "focused client set cursor", .{});
        c.wlr_cursor_set_surface(
            self.wlr_cursor,
            event.surface,
            event.hotspot_x,
            event.hotspot_y,
        );
    }
}

fn cursorMoveConstraints(self: *Self, _position: f64, _output: u64, _view: u64) i32 {
    const position: i32 = @floatToInt(i32, _position);
    const view: i32 = @intCast(i32, _view);
    const border_width = @intCast(i32, self.grabbed_view.output.root.server.config.border_width);
    const useable: i32 = @intCast(i32, _output - _view) - border_width;

    var new: i32 = position;
    if (position > useable) {
        new = useable;
    } else if (position < border_width) {
        new = border_width;
    }
    return new;
}

/// Moves grabbed view and returns new cursor position
fn processMotionMove(self: *Self, x_in: f64, y_in: f64) CursorPosition {
    // Get new X and Y of cursor and view.
    // Width and height of surface will stay the same.
    self.grabbed_view.pending.box.x = cursorMoveConstraints(
        self,
        x_in - self.grab_delta_x,
        self.grab_output_width,
        self.grabbed_view.pending.box.width,
    );
    self.grabbed_view.pending.box.y = cursorMoveConstraints(
        self,
        y_in - self.grab_delta_y,
        self.grab_output_height,
        self.grabbed_view.pending.box.height,
    );

    // Apply new pending state (no need for a transaction as size didn't change)
    self.grabbed_view.current = self.grabbed_view.pending;

    // This function returns the cursor position so that the calling function
    // can do the cursor movement.
    return .{
        .x = @intToFloat(f64, self.grabbed_view.current.box.x) + self.grab_delta_x,
        .y = @intToFloat(f64, self.grabbed_view.current.box.y) + self.grab_delta_y,
    };
}

fn processMotionPassthrough(self: *Self, time: u32) void {
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
                log.debug(.cursor, "pointer notify enter at ({},{})", .{ sx, sy });
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
    const wlr_output = c.wlr_output_layout_output_at(root.wlr_output_layout, lx, ly) orelse return null;
    const output = util.voidCast(Output, wlr_output.*.data orelse return null);

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
    if (layerSurfaceAt(output.*, output.layers[layer_idxs[0]], ox, oy, sx, sy, false)) |s| return s;

    // Check top-background popups only
    for (layer_idxs[1..4]) |idx|
        if (layerSurfaceAt(output.*, output.layers[idx], ox, oy, sx, sy, true)) |s| return s;

    // Check top layer
    if (layerSurfaceAt(output.*, output.layers[layer_idxs[1]], ox, oy, sx, sy, false)) |s| return s;

    // Check views
    if (viewSurfaceAt(output.*, ox, oy, sx, sy)) |s| return s;

    // Check the bottom-background layers
    for (layer_idxs[2..4]) |idx|
        if (layerSurfaceAt(output.*, output.layers[idx], ox, oy, sx, sy, false)) |s| return s;

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

/// Find the topmost visible view surface (incl. popups) at ox,oy.
fn viewSurfaceAt(output: Output, ox: f64, oy: f64, sx: *f64, sy: *f64) ?*c.wlr_surface {
    // Focused views are rendered on top, so look for them first.
    var it = ViewStack(View).iterator(output.views.first, output.current.tags);
    while (it.next()) |node| {
        if (!node.view.focused) continue;
        if (node.view.surfaceAt(ox, oy, sx, sy)) |found| return found;
    }

    it = ViewStack(View).iterator(output.views.first, output.current.tags);
    while (it.next()) |node| {
        if (node.view.surfaceAt(ox, oy, sx, sy)) |found| return found;
    }

    return null;
}
