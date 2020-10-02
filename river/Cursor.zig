// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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
const math = std.math;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;

const c = @import("c.zig");
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
};

const default_size = 24;

const log = std.log.scoped(.cursor);

/// Current cursor mode as well as any state needed to implement that mode
mode: Mode = .passthrough,

seat: *Seat,
wlr_cursor: *wlr.Cursor,
pointer_gestures: *wlr.PointerGesturesV1,
xcursor_manager: *wlr.XcursorManager,

constraint: ?*wlr.PointerConstraintV1 = null,

/// Number of distinct buttons currently pressed
pressed_count: u32 = 0,

axis: wl.Listener(*wlr.Pointer.event.Axis) = wl.Listener(*wlr.Pointer.event.Axis).init(handleAxis),
frame: wl.Listener(*wlr.Cursor) = wl.Listener(*wlr.Cursor).init(handleFrame),
// zig fmt: off
button: wl.Listener(*wlr.Pointer.event.Button) =
    wl.Listener(*wlr.Pointer.event.Button).init(handleButton),
motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) =
    wl.Listener(*wlr.Pointer.event.MotionAbsolute).init(handleMotionAbsolute),
motion: wl.Listener(*wlr.Pointer.event.Motion) =
    wl.Listener(*wlr.Pointer.event.Motion).init(handleMotion),
pinch_begin: wl.Listener(*wlr.Pointer.event.PinchBegin) =
    wl.Listener(*wlr.Pointer.event.PinchBegin).init(handlePinchBegin),
pinch_update: wl.Listener(*wlr.Pointer.event.PinchUpdate) =
    wl.Listener(*wlr.Pointer.event.PinchUpdate).init(handlePinchUpdate),
pinch_end: wl.Listener(*wlr.Pointer.event.PinchEnd) =
    wl.Listener(*wlr.Pointer.event.PinchEnd).init(handlePinchEnd),
request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) =
    wl.Listener(*wlr.Seat.event.RequestSetCursor).init(handleRequestSetCursor),
swipe_begin: wl.Listener(*wlr.Pointer.event.SwipeBegin) =
    wl.Listener(*wlr.Pointer.event.SwipeBegin).init(handleSwipeBegin),
swipe_update: wl.Listener(*wlr.Pointer.event.SwipeUpdate) =
    wl.Listener(*wlr.Pointer.event.SwipeUpdate).init(handleSwipeUpdate),
swipe_end: wl.Listener(*wlr.Pointer.event.SwipeEnd) =
    wl.Listener(*wlr.Pointer.event.SwipeEnd).init(handleSwipeEnd),
// zig fmt: on

pub fn init(self: *Self, seat: *Seat) !void {
    const wlr_cursor = try wlr.Cursor.create();
    errdefer wlr_cursor.destroy();
    wlr_cursor.attachOutputLayout(seat.input_manager.server.root.output_layout);

    // This is here so that self.xcursor_manager doesn't need to be an
    // optional pointer. This isn't optimal as it does a needless allocation,
    // but this is not a hot path.
    const xcursor_manager = try wlr.XcursorManager.create(null, default_size);
    errdefer xcursor_manager.destroy();

    self.* = .{
        .seat = seat,
        .wlr_cursor = wlr_cursor,
        .pointer_gestures = try wlr.PointerGesturesV1.create(seat.input_manager.server.wl_server),
        .xcursor_manager = xcursor_manager,
    };
    try self.setTheme(null, null);

    // wlr_cursor *only* displays an image on screen. It does not move around
    // when the pointer moves. However, we can attach input devices to it, and
    // it will generate aggregate events for all of them. In these events, we
    // can choose how we want to process them, forwarding them to clients and
    // moving the cursor around. See following post for more detail:
    // https://drewdevault.com/2018/07/17/Input-handling-in-wlroots.html
    wlr_cursor.events.axis.add(&self.axis);
    wlr_cursor.events.button.add(&self.button);
    wlr_cursor.events.frame.add(&self.frame);
    wlr_cursor.events.motion_absolute.add(&self.motion_absolute);
    wlr_cursor.events.motion.add(&self.motion);
    wlr_cursor.events.swipe_begin.add(&self.swipe_begin);
    wlr_cursor.events.swipe_update.add(&self.swipe_update);
    wlr_cursor.events.swipe_end.add(&self.swipe_end);
    wlr_cursor.events.pinch_begin.add(&self.pinch_begin);
    wlr_cursor.events.pinch_update.add(&self.pinch_update);
    wlr_cursor.events.pinch_end.add(&self.pinch_end);
    seat.wlr_seat.events.request_set_cursor.add(&self.request_set_cursor);
}

pub fn deinit(self: *Self) void {
    self.xcursor_manager.destroy();
    self.wlr_cursor.destroy();
}

/// Set the cursor theme for the given seat, as well as the xwayland theme if
/// this is the default seat. Either argument may be null, in which case a
/// default will be used.
pub fn setTheme(self: *Self, theme: ?[*:0]const u8, _size: ?u32) !void {
    const server = self.seat.input_manager.server;
    const size = _size orelse default_size;

    self.xcursor_manager.destroy();
    self.xcursor_manager = try wlr.XcursorManager.create(theme, size);

    // For each output, ensure a theme of the proper scale is loaded
    var it = server.root.outputs.first;
    while (it) |node| : (it = node.next) {
        const wlr_output = node.data.wlr_output;
        self.xcursor_manager.load(wlr_output.scale) catch
            log.err("failed to load xcursor theme '{}' at scale {}", .{ theme, wlr_output.scale });
    }

    // If this cursor belongs to the default seat, set the xcursor environment
    // variables and the xwayland cursor theme.
    if (self.seat == self.seat.input_manager.defaultSeat()) {
        const size_str = try std.fmt.allocPrint0(util.gpa, "{}", .{size});
        defer util.gpa.free(size_str);
        if (c.setenv("XCURSOR_SIZE", size_str, 1) < 0) return error.OutOfMemory;
        if (theme) |t| if (c.setenv("XCURSOR_THEME", t, 1) < 0) return error.OutOfMemory;

        if (build_options.xwayland) {
            self.xcursor_manager.load(1) catch {
                log.err("failed to load xcursor theme '{}' at scale 1", .{theme});
                return;
            };
            const wlr_xcursor = self.xcursor_manager.getXcursor("left_ptr", 1).?;
            const image = wlr_xcursor.images[0];
            server.xwayland.setCursor(
                image.buffer,
                image.width * 4,
                image.width,
                image.height,
                @intCast(i32, image.hotspot_x),
                @intCast(i32, image.hotspot_y),
            );
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
    self.xcursor_manager.setCursorImage("left_ptr", self.wlr_cursor);
    self.seat.wlr_seat.pointerNotifyClearFocus();
}

/// Axis event is a scroll wheel or similiar
fn handleAxis(listener: *wl.Listener(*wlr.Pointer.event.Axis), event: *wlr.Pointer.event.Axis) void {
    const self = @fieldParentPtr(Self, "axis", listener);

    self.seat.handleActivity();

    // Notify the client with pointer focus of the axis event.
    self.seat.wlr_seat.pointerNotifyAxis(
        event.time_msec,
        event.orientation,
        event.delta,
        event.delta_discrete,
        event.source,
    );
}

fn handleButton(listener: *wl.Listener(*wlr.Pointer.event.Button), event: *wlr.Pointer.event.Button) void {
    const self = @fieldParentPtr(Self, "button", listener);

    self.seat.handleActivity();

    if (event.state == .pressed) {
        self.pressed_count += 1;
    } else {
        std.debug.assert(self.pressed_count > 0);
        self.pressed_count -= 1;
        if (self.pressed_count == 0 and self.mode != .passthrough) {
            self.leaveMode(event);
            return;
        }
    }

    var sx: f64 = undefined;
    var sy: f64 = undefined;
    if (self.surfaceAt(self.wlr_cursor.x, self.wlr_cursor.y, &sx, &sy)) |surface| {
        // If the found surface is a keyboard inteactive layer surface,
        // give it keyboard focus.
        if (surface.isLayerSurface()) {
            const wlr_layer_surface = wlr.LayerSurfaceV1.fromWlrSurface(surface);
            if (wlr_layer_surface.current.keyboard_interactive == .exclusive) {
                const layer_surface = @intToPtr(*LayerSurface, wlr_layer_surface.data);
                self.seat.focusOutput(layer_surface.output);
                self.seat.setFocusRaw(.{ .layer = layer_surface });
            }
        }

        // If the target surface has a view, give that view keyboard focus and
        // perhaps enter move/resize mode.
        if (View.fromWlrSurface(surface)) |view| {
            if (event.state == .pressed and self.pressed_count == 1) {
                // If there is an active mapping for this button which is
                // handled we are done here
                if (self.handlePointerMapping(event, view)) return;
                // Otherwise enter cursor down mode
                self.enterMode(.down, view);
            }
        }

        _ = self.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
    }
}

fn handlePinchBegin(
    listener: *wl.Listener(*wlr.Pointer.event.PinchBegin),
    event: *wlr.Pointer.event.PinchBegin,
) void {
    const self = @fieldParentPtr(Self, "pinch_begin", listener);
    self.pointer_gestures.sendPinchBegin(
        self.seat.wlr_seat,
        event.time_msec,
        event.fingers,
    );
}

fn handlePinchUpdate(
    listener: *wl.Listener(*wlr.Pointer.event.PinchUpdate),
    event: *wlr.Pointer.event.PinchUpdate,
) void {
    const self = @fieldParentPtr(Self, "pinch_update", listener);
    self.pointer_gestures.sendPinchUpdate(
        self.seat.wlr_seat,
        event.time_msec,
        event.dx,
        event.dy,
        event.scale,
        event.rotation,
    );
}

fn handlePinchEnd(
    listener: *wl.Listener(*wlr.Pointer.event.PinchEnd),
    event: *wlr.Pointer.event.PinchEnd,
) void {
    const self = @fieldParentPtr(Self, "pinch_end", listener);
    self.pointer_gestures.sendPinchEnd(
        self.seat.wlr_seat,
        event.time_msec,
        event.cancelled,
    );
}

fn handleSwipeBegin(
    listener: *wl.Listener(*wlr.Pointer.event.SwipeBegin),
    event: *wlr.Pointer.event.SwipeBegin,
) void {
    const self = @fieldParentPtr(Self, "swipe_begin", listener);
    self.pointer_gestures.sendSwipeBegin(
        self.seat.wlr_seat,
        event.time_msec,
        event.fingers,
    );
}

fn handleSwipeUpdate(
    listener: *wl.Listener(*wlr.Pointer.event.SwipeUpdate),
    event: *wlr.Pointer.event.SwipeUpdate,
) void {
    const self = @fieldParentPtr(Self, "swipe_update", listener);
    self.pointer_gestures.sendSwipeUpdate(
        self.seat.wlr_seat,
        event.time_msec,
        event.dx,
        event.dy,
    );
}

fn handleSwipeEnd(
    listener: *wl.Listener(*wlr.Pointer.event.SwipeEnd),
    event: *wlr.Pointer.event.SwipeEnd,
) void {
    const self = @fieldParentPtr(Self, "swipe_end", listener);
    self.pointer_gestures.sendSwipeEnd(
        self.seat.wlr_seat,
        event.time_msec,
        event.cancelled,
    );
}

/// Handle the mapping for the passed button if any. Returns true if there
/// was a mapping and the button was handled.
fn handlePointerMapping(self: *Self, event: *wlr.Pointer.event.Button, view: *View) bool {
    const wlr_keyboard = self.seat.wlr_seat.getKeyboard() orelse return false;
    const modifiers = wlr_keyboard.getModifiers();

    const fullscreen = view.current.fullscreen or view.pending.fullscreen;

    const config = self.seat.input_manager.server.config;
    return for (config.modes.items[self.seat.mode_id].pointer_mappings.items) |mapping| {
        if (event.button == mapping.event_code and std.meta.eql(modifiers, mapping.modifiers)) {
            switch (mapping.action) {
                .move => if (!fullscreen) self.enterMode(.move, view),
                .resize => if (!fullscreen) self.enterMode(.resize, view),
            }
            break true;
        }
    } else false;
}

/// Frame events are sent after regular pointer events to group multiple
/// events together. For instance, two axis events may happen at the same
/// time, in which case a frame event won't be sent in between.
fn handleFrame(listener: *wl.Listener(*wlr.Cursor), wlr_cursor: *wlr.Cursor) void {
    const self = @fieldParentPtr(Self, "frame", listener);
    self.seat.wlr_seat.pointerNotifyFrame();
}

/// This event is forwarded by the cursor when a pointer emits an _absolute_
/// motion event, from 0..1 on each axis. This happens, for example, when
/// wlroots is running under a Wayland window rather than KMS+DRM, and you
/// move the mouse over the window. You could enter the window from any edge,
/// so we have to warp the mouse there. There is also some hardware which
/// emits these events.
fn handleMotionAbsolute(
    listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
    event: *wlr.Pointer.event.MotionAbsolute,
) void {
    const self = @fieldParentPtr(Self, "motion_absolute", listener);

    self.seat.handleActivity();

    var lx: f64 = undefined;
    var ly: f64 = undefined;
    self.wlr_cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);

    const dx = lx - self.wlr_cursor.x;
    const dy = ly - self.wlr_cursor.y;
    self.processMotion(event.device, event.time_msec, dx, dy, dx, dy);
}

/// This event is forwarded by the cursor when a pointer emits a _relative_
/// pointer motion event (i.e. a delta)
fn handleMotion(
    listener: *wl.Listener(*wlr.Pointer.event.Motion),
    event: *wlr.Pointer.event.Motion,
) void {
    const self = @fieldParentPtr(Self, "motion", listener);

    self.seat.handleActivity();

    self.processMotion(event.device, event.time_msec, event.delta_x, event.delta_y, event.unaccel_dx, event.unaccel_dy);
}

fn handleRequestSetCursor(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
    event: *wlr.Seat.event.RequestSetCursor,
) void {
    // This event is rasied by the seat when a client provides a cursor image
    const self = @fieldParentPtr(Self, "request_set_cursor", listener);
    const focused_client = self.seat.wlr_seat.pointer_state.focused_client;

    // This can be sent by any client, so we check to make sure this one is
    // actually has pointer focus first.
    if (focused_client == event.seat_client) {
        // Once we've vetted the client, we can tell the cursor to use the
        // provided surface as the cursor image. It will set the hardware cursor
        // on the output that it's currently on and continue to do so as the
        // cursor moves between outputs.
        log.debug("focused client set cursor", .{});
        self.wlr_cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
    }
}

/// Find the topmost surface under the output layout coordinates lx/ly
/// returns the surface if found and sets the sx/sy parametes to the
/// surface coordinates.
fn surfaceAt(self: Self, lx: f64, ly: f64, sx: *f64, sy: *f64) ?*wlr.Surface {
    // Find the output to check
    const root = self.seat.input_manager.server.root;
    const wlr_output = root.output_layout.outputAt(lx, ly) orelse return null;
    const output = @intToPtr(*Output, wlr_output.data);

    // Get output-local coords from the layout coords
    var ox = lx;
    var oy = ly;
    root.output_layout.outputCoords(wlr_output, &ox, &oy);

    // Check overlay layer incl. popups
    if (layerSurfaceAt(output.*, output.getLayer(.overlay).*, ox, oy, sx, sy, false)) |s| return s;

    // Check top-background popups only
    for ([_]zwlr.LayerShellV1.Layer{ .top, .bottom, .background }) |layer|
        if (layerSurfaceAt(output.*, output.getLayer(layer).*, ox, oy, sx, sy, true)) |s| return s;

    // Check top layer
    if (layerSurfaceAt(output.*, output.getLayer(.top).*, ox, oy, sx, sy, false)) |s| return s;

    // Check views
    if (viewSurfaceAt(output.*, ox, oy, sx, sy)) |s| return s;

    // Check the bottom-background layers
    for ([_]zwlr.LayerShellV1.Layer{ .bottom, .background }) |layer|
        if (layerSurfaceAt(output.*, output.getLayer(layer).*, ox, oy, sx, sy, false)) |s| return s;

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
) ?*wlr.Surface {
    var it = layer.first;
    while (it) |node| : (it = node.next) {
        const layer_surface = &node.data;
        if (layer_surface.wlr_layer_surface.surfaceAt(
            ox - @intToFloat(f64, layer_surface.box.x),
            oy - @intToFloat(f64, layer_surface.box.y),
            sx,
            sy,
        )) |found| {
            if (!popups_only) {
                return found;
            } else if (found.isXdgSurface() and wlr.XdgSurface.fromWlrSurface(found).role == .popup) {
                return found;
            }
        }
    }
    return null;
}

/// Find the topmost visible view surface (incl. popups) at ox,oy.
fn viewSurfaceAt(output: Output, ox: f64, oy: f64, sx: *f64, sy: *f64) ?*wlr.Surface {
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

/// Enter move or resize mode
pub fn enterMode(self: *Self, mode: @TagType(Mode), view: *View) void {
    log.debug("enter {} mode", .{@tagName(mode)});

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

            // Automatically float all views being moved by the pointer, if
            // their dimensions are set by a layout client. If however the views
            // are unarranged, leave them as non-floating so the next active
            // layout can affect them.
            if (!view.current.float and view.output.current.layout != null) {
                view.pending.float = true;
                view.float_box = view.current.box;
                view.applyPending();
            }

            // Clear cursor focus, so that the surface does not receive events
            self.seat.wlr_seat.pointerNotifyClearFocus();

            self.xcursor_manager.setCursorImage(
                if (mode == .move) "move" else "se-resize",
                self.wlr_cursor,
            );
        },
    }
}

/// Return from down/move/resize to passthrough
fn leaveMode(self: *Self, event: *wlr.Pointer.event.Button) void {
    std.debug.assert(self.mode != .passthrough);

    log.debug("leave {} mode", .{@tagName(self.mode)});

    // If we were in down mode, we need pass along the release event
    if (self.mode == .down)
        _ = self.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);

    self.mode = .passthrough;
    self.passthrough(event.time_msec);
}

fn processMotion(self: *Self, device: *wlr.InputDevice, time: u32, delta_x: f64, delta_y: f64, unaccel_dx: f64, unaccel_dy: f64) void {
    self.seat.input_manager.relative_pointer_manager.sendRelativeMotion(
        self.seat.wlr_seat,
        @as(u64, time) * 1000,
        delta_x,
        delta_y,
        unaccel_dx,
        unaccel_dy,
    );
    var dx: f64 = delta_x;
    var dy: f64 = delta_y;
    if (self.constraint) |constraint| {
        if (self.mode == .passthrough or self.mode == .down) {
            if (constraint.type == .locked) return;

            var sx: f64 = undefined;
            var sy: f64 = undefined;
            const surface = self.surfaceAt(self.wlr_cursor.x, self.wlr_cursor.y, &sx, &sy);

            if (surface != constraint.surface) return;

            var sx_con: f64 = undefined;
            var sy_con: f64 = undefined;
            if (!wlr.region.confine(&constraint.region, sx, sy, sx + dx, sy + dy, &sx_con, &sy_con)) {
                return;
            }

            dx = sx_con - sx;
            dy = sy_con - sy;
        }
    }
    switch (self.mode) {
        .passthrough => {
            self.wlr_cursor.move(device, dx, dy);
            self.passthrough(time);
        },
        .down => |view| {
            self.wlr_cursor.move(device, dx, dy);
            // This takes surface-local coordinates
            const output_box = view.output.root.output_layout.getBox(view.output.wlr_output).?;
            self.seat.wlr_seat.pointerNotifyMotion(
                time,
                self.wlr_cursor.x - @intToFloat(f64, output_box.x + view.current.box.x - view.surface_box.x),
                self.wlr_cursor.y - @intToFloat(f64, output_box.y + view.current.box.y - view.surface_box.y),
            );
        },
        .move => |view| {
            view.move(@floatToInt(i32, delta_x), @floatToInt(i32, delta_y));
            self.wlr_cursor.move(
                device,
                @intToFloat(f64, view.pending.box.x - view.current.box.x),
                @intToFloat(f64, view.pending.box.y - view.current.box.y),
            );
            view.applyPending();
        },
        .resize => |data| {
            const config = &self.seat.input_manager.server.config;
            const border_width = if (data.view.draw_borders) config.border_width else 0;

            // Set width/height of view, clamp to view size constraints and output dimensions
            const box = &data.view.pending.box;
            box.width = @intCast(u32, math.max(0, @intCast(i32, box.width) + @floatToInt(i32, delta_x)));
            box.height = @intCast(u32, math.max(0, @intCast(i32, box.height) + @floatToInt(i32, delta_y)));

            data.view.applyConstraints();

            const output_resolution = data.view.output.getEffectiveResolution();
            box.width = math.min(box.width, output_resolution.width - border_width - @intCast(u32, box.x));
            box.height = math.min(box.height, output_resolution.height - border_width - @intCast(u32, box.y));

            data.view.applyPending();

            // Keep cursor locked to the original offset from the bottom right corner
            self.wlr_cursor.warpClosest(
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
    if (self.surfaceAt(self.wlr_cursor.x, self.wlr_cursor.y, &sx, &sy)) |surface| {
        // If input is allowed on the surface, send pointer enter and motion
        // events. Note that wlroots won't actually send an enter event if
        // the surface has already been entered.
        if (self.seat.input_manager.inputAllowed(surface)) {
            // The focus change must be checked before sending enter events
            const focus_change = self.seat.wlr_seat.pointer_state.focused_surface != surface;

            self.seat.wlr_seat.pointerNotifyEnter(surface, sx, sy);
            self.seat.wlr_seat.pointerNotifyMotion(time, sx, sy);

            const follow_mode = config.focus_follows_cursor;
            if (follow_mode == .strict or (follow_mode == .normal and focus_change)) {
                if (View.fromWlrSurface(surface)) |view| {
                    self.seat.focusOutput(view.output);
                    self.seat.focus(view);
                    root.startTransaction();
                }
            }
        }
    } else {
        // There is either no surface under the cursor or input is disallowed
        // Reset the cursor image to the default and clear focus.
        self.clearFocus();
    }
}
