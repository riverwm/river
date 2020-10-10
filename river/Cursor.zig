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

const Mode = union(enum) {
    passthrough: void,
    down: *View,
    move: *View,
    resize: struct {
        view: *View,
        /// Offset from the lower right corner of the view
        offset_x: i32,
        offset_y: i32,
    },

    /// Enter move or resize mode
    fn enter(self: *Self, mode: @TagType(Mode), event: *c.wlr_event_pointer_button, view: *View) void {
        log.debug(.cursor, "enter {} mode", .{@tagName(mode)});

        self.seat.focus(view);

        switch (mode) {
            .passthrough => unreachable,
            .down => {
                self.mode = .{ .down = view };
                view.output.root.startTransaction();
            },
            .move, .resize => {
                const cur_box = &view.current.box;
                self.mode = switch (mode) {
                    .passthrough, .down => unreachable,
                    .move => .{ .move = view },
                    .resize => .{
                        .resize = .{
                            .view = view,
                            .offset_x = cur_box.x + @intCast(i32, cur_box.width) - @floatToInt(i32, self.wlr_cursor.x),
                            .offset_y = cur_box.y + @intCast(i32, cur_box.height) - @floatToInt(i32, self.wlr_cursor.y),
                        },
                    },
                };

                // Automatically float all views being moved by the pointer
                if (!view.current.float) {
                    view.pending.float = true;
                    view.float_box = view.current.box;
                    view.applyPending();
                }

                // Clear cursor focus, so that the surface does not receive events
                c.wlr_seat_pointer_clear_focus(self.seat.wlr_seat);

                c.wlr_xcursor_manager_set_cursor_image(
                    self.wlr_xcursor_manager,
                    if (mode == .move) "move" else "se-resize",
                    self.wlr_cursor,
                );
            },
        }
    }

    /// Return from down/move/resize to passthrough
    fn leave(self: *Self, event: *c.wlr_event_pointer_button) void {
        std.debug.assert(self.mode != .passthrough);

        log.debug(.cursor, "leave {} mode", .{@tagName(self.mode)});

        // If we were in down mode, we need pass along the release event
        if (self.mode == .down)
            _ = c.wlr_seat_pointer_notify_button(
                self.seat.wlr_seat,
                event.time_msec,
                event.button,
                event.state,
            );

        self.mode = .passthrough;
        passthrough(self, event.time_msec);
    }

    fn processMotion(self: *Self, device: *c.wlr_input_device, time: u32, delta_x: f64, delta_y: f64) void {
        const config = self.seat.input_manager.server.config;
        if (self.active_constraint != null) {
            return;
        }

        switch (self.mode) {
            .passthrough => {
                c.wlr_cursor_move(self.wlr_cursor, device, delta_x, delta_y);
                passthrough(self, time);
            },
            .down => |view| {
                c.wlr_cursor_move(self.wlr_cursor, device, delta_x, delta_y);
                c.wlr_seat_pointer_notify_motion(
                    self.seat.wlr_seat,
                    time,
                    self.wlr_cursor.x - @intToFloat(f64, view.current.box.x),
                    self.wlr_cursor.y - @intToFloat(f64, view.current.box.y),
                );
            },
            .move => |view| {
                const border_width = if (view.draw_borders) config.border_width else 0;

                // Set x/y of cursor and view, clamp to output dimensions
                const output_resolution = view.output.getEffectiveResolution();
                view.pending.box.x = std.math.clamp(
                    view.pending.box.x + @floatToInt(i32, delta_x),
                    @intCast(i32, border_width),
                    @intCast(i32, output_resolution.width - view.pending.box.width - border_width),
                );
                view.pending.box.y = std.math.clamp(
                    view.pending.box.y + @floatToInt(i32, delta_y),
                    @intCast(i32, border_width),
                    @intCast(i32, output_resolution.height - view.pending.box.height - border_width),
                );

                c.wlr_cursor_move(
                    self.wlr_cursor,
                    device,
                    @intToFloat(f64, view.pending.box.x - view.current.box.x),
                    @intToFloat(f64, view.pending.box.y - view.current.box.y),
                );

                view.applyPending();
            },
            .resize => |data| {
                const border_width = if (data.view.draw_borders) config.border_width else 0;

                // Set width/height of view, clamp to view size constraints and output dimensions
                const box = &data.view.pending.box;
                box.width = @intCast(u32, std.math.max(0, @intCast(i32, box.width) + @floatToInt(i32, delta_x)));
                box.height = @intCast(u32, std.math.max(0, @intCast(i32, box.height) + @floatToInt(i32, delta_y)));

                data.view.applyConstraints();

                const output_resolution = data.view.output.getEffectiveResolution();
                box.width = std.math.min(box.width, output_resolution.width - border_width - @intCast(u32, box.x));
                box.height = std.math.min(box.height, output_resolution.height - border_width - @intCast(u32, box.y));

                data.view.applyPending();

                // Keep cursor locked to the original offset from the bottom right corner
                c.wlr_cursor_warp_closest(
                    self.wlr_cursor,
                    device,
                    @intToFloat(f64, box.x + @intCast(i32, box.width) - data.offset_x),
                    @intToFloat(f64, box.y + @intCast(i32, box.height) - data.offset_y),
                );
            },
        }
    }

    /// Pass an event on to the surface under the cursor, if any.
    fn passthrough(self: *Self, time: u32) void {
        const root = &self.seat.input_manager.server.root;
        const config = self.seat.input_manager.server.config;

        var sx: f64 = undefined;
        var sy: f64 = undefined;
        if (self.surfaceAt(self.wlr_cursor.x, self.wlr_cursor.y, &sx, &sy)) |wlr_surface| {
            // If input is allowed on the surface, send pointer enter and motion
            // events. Note that wlroots won't actually send an enter event if
            // the surface has already been entered.
            if (self.seat.input_manager.inputAllowed(wlr_surface)) {
                // The focus change must be checked before sending enter events
                const focus_change = self.seat.wlr_seat.pointer_state.focused_surface != wlr_surface;

                c.wlr_seat_pointer_notify_enter(self.seat.wlr_seat, wlr_surface, sx, sy);
                c.wlr_seat_pointer_notify_motion(self.seat.wlr_seat, time, sx, sy);
                if (View.fromWlrSurface(wlr_surface)) |view| {
                    // Change focus according to config
                    switch (config.focus_follows_cursor) {
                        .disabled => {},
                        .normal => {
                            // Only refocus when the cursor entered a new surface
                            if (focus_change) {
                                self.seat.focus(view);
                                root.startTransaction();
                            }
                        },
                        .strict => {
                            self.seat.focus(view);
                            root.startTransaction();
                        },
                    }
                }

                return;
            }
        } else {
            // There is either no surface under the cursor or input is disallowed
            // Reset the cursor image to the default and clear focus.
            self.clearFocus();
        }
    }
};

const default_size = 24;

seat: *Seat,
wlr_cursor: *c.wlr_cursor,
wlr_xcursor_manager: *c.wlr_xcursor_manager,

active_constraint: ?*c.wlr_pointer_constraint_v1,
active_confine_requires_warp: bool = undefined,
constraint_commit: c.wl_listener = undefined,

/// Number of distinct buttons currently pressed
pressed_count: u32 = 0,

/// Current cursor mode as well as any state needed to implement that mode
mode: Mode = .passthrough,

listen_axis: c.wl_listener = undefined,
listen_button: c.wl_listener = undefined,
listen_frame: c.wl_listener = undefined,
listen_motion_absolute: c.wl_listener = undefined,
listen_motion: c.wl_listener = undefined,
listen_request_set_cursor: c.wl_listener = undefined,

pub fn init(self: *Self, seat: *Seat) !void {
    const wlr_cursor = c.wlr_cursor_create() orelse return error.OutOfMemory;
    errdefer c.wlr_cursor_destroy(wlr_cursor);
    c.wlr_cursor_attach_output_layout(wlr_cursor, seat.input_manager.server.root.wlr_output_layout);

    // This is here so that self.wlr_xcursor_manager doesn't need to be an
    // optional pointer. This isn't optimal as it does a needless allocation,
    // but this is not a hot path.
    const wlr_xcursor_manager = c.wlr_xcursor_manager_create(null, default_size) orelse return error.OutOfMemory;
    errdefer c.wlr_xcursor_manager_destroy(wlr_xcursor_manager);

    self.* = .{
        .seat = seat,
        .wlr_cursor = wlr_cursor,
        .wlr_xcursor_manager = wlr_xcursor_manager,
        .active_constraint = null,
    };
        // .active_confine_requires_warp = false,
        // .constraint_commit = unreachable,
    try self.setTheme(null, null);

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
    if (self.seat == self.seat.input_manager.defaultSeat()) {
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

pub fn isCursorActionTarget(self: Self, view: *const View) bool {
    return switch (self.mode) {
        .passthrough => false,
        .down => |target_view| target_view == view,
        .move => |target_view| target_view == view,
        .resize => |data| data.view == view,
    };
}

pub fn handleViewUnmap(self: *Self, view: *View) void {
    if (self.isCursorActionTarget(view)) {
        self.mode = .passthrough;
        self.clearFocus();
    }
}

fn clearFocus(self: Self) void {
    c.wlr_xcursor_manager_set_cursor_image(
        self.wlr_xcursor_manager,
        "left_ptr",
        self.wlr_cursor,
    );
    c.wlr_seat_pointer_clear_focus(self.seat.wlr_seat);
}

fn handleAxis(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is forwarded by the cursor when a pointer emits an axis event,
    // for example when you move the scroll wheel.
    const self = @fieldParentPtr(Self, "listen_axis", listener.?);
    const event = util.voidCast(c.wlr_event_pointer_axis, data.?);

    self.seat.handleActivity();

    // Notify the client with pointer focus of the axis event.
    c.wlr_seat_pointer_notify_axis(
        self.seat.wlr_seat,
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
    const event = util.voidCast(c.wlr_event_pointer_button, data.?);

    self.seat.handleActivity();

    if (event.state == .WLR_BUTTON_PRESSED) {
        self.pressed_count += 1;
    } else {
        std.debug.assert(self.pressed_count > 0);
        self.pressed_count -= 1;
        if (self.pressed_count == 0 and self.mode != .passthrough) {
            Mode.leave(self, event);
            return;
        }
    }

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

        // If the target surface has a view, give that view keyboard focus and
        // perhaps enter move/resize mode.
        if (View.fromWlrSurface(wlr_surface)) |view| {
            if (event.state == .WLR_BUTTON_PRESSED and self.pressed_count == 1) {
                // If there is an active mapping for this button which is
                // handled we are done here
                if (self.handlePointerMapping(event, view)) return;
                // Otherwise enter cursor down mode
                Mode.enter(self, .down, event, view);
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

/// Handle the mapping for the passed button if any. Returns true if there
/// was a mapping and the button was handled.
fn handlePointerMapping(self: *Self, event: *c.wlr_event_pointer_button, view: *View) bool {
    const wlr_keyboard = c.wlr_seat_get_keyboard(self.seat.wlr_seat);
    const modifiers = c.wlr_keyboard_get_modifiers(wlr_keyboard);

    const fullscreen = view.current.fullscreen or view.pending.fullscreen;

    const config = self.seat.input_manager.server.config;
    return for (config.modes.items[self.seat.mode_id].pointer_mappings.items) |mapping| {
        if (event.button == mapping.event_code and modifiers == mapping.modifiers) {
            switch (mapping.action) {
                .move => if (!fullscreen) Mode.enter(self, .move, event, view),
                .resize => if (!fullscreen) Mode.enter(self, .resize, event, view),
            }
            break true;
        }
    } else false;
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

    self.seat.handleActivity();

    var lx: f64 = undefined;
    var ly: f64 = undefined;
    c.wlr_cursor_absolute_to_layout_coords(self.wlr_cursor, event.device, event.x, event.y, &lx, &ly);

    Mode.processMotion(self, event.device, event.time_msec, lx - self.wlr_cursor.x, ly - self.wlr_cursor.y);
}

fn handleMotion(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is forwarded by the cursor when a pointer emits a _relative_
    // pointer motion event (i.e. a delta)
    const self = @fieldParentPtr(Self, "listen_motion", listener.?);
    const event = util.voidCast(c.wlr_event_pointer_motion, data.?);

    self.seat.handleActivity();

    Mode.processMotion(self, event.device, event.time_msec, event.delta_x, event.delta_y);
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
    var it = ViewStack(View).iter(output.views.first, .forward, output.current.tags, surfaceAtFilter);
    while (it.next()) |view| {
        if (view.current.focus == 0) continue;
        if (view.surfaceAt(ox, oy, sx, sy)) |found| return found;
    }

    it = ViewStack(View).iter(output.views.first, .forward, output.current.tags, surfaceAtFilter);
    while (it.next()) |view| {
        if (view.surfaceAt(ox, oy, sx, sy)) |found| return found;
    }

    return null;
}

fn surfaceAtFilter(view: *View, filter_tags: u32) bool {
    return !view.destroying and view.current.tags & filter_tags != 0;
}
