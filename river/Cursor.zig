// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const Cursor = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const os = std.os;
const math = std.math;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;

const c = @import("c.zig");
const server = &@import("main.zig").server;
const util = @import("util.zig");

const Config = @import("Config.zig");
const DragIcon = @import("DragIcon.zig");
const InputDevice = @import("InputDevice.zig");
const LayerSurface = @import("LayerSurface.zig");
const LockSurface = @import("LockSurface.zig");
const Output = @import("Output.zig");
const PointerConstraint = @import("PointerConstraint.zig");
const Root = @import("Root.zig");
const Seat = @import("Seat.zig");
const Tablet = @import("Tablet.zig");
const TabletTool = @import("TabletTool.zig");
const View = @import("View.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");

const Mode = union(enum) {
    passthrough: void,
    down: struct {
        // TODO: To handle the surface with pointer focus being moved during
        // down mode we need to store the starting location of the surface as
        // well and take that into account. This is currently not at all easy
        // to do, but moing to the wlroots scene graph will allow us to fix this.

        // Initial cursor position in layout coordinates
        lx: f64,
        ly: f64,
        // Initial cursor position in surface-local coordinates
        sx: f64,
        sy: f64,
    },
    move: struct {
        view: *View,

        /// View coordinates are stored as i32s as they are in logical pixels.
        /// However, it is possible to move the cursor by a fraction of a
        /// logical pixel and this happens in practice with low dpi, high
        /// polling rate mice. Therefore we must accumulate the current
        /// fractional offset of the mouse to avoid rounding down tiny
        /// motions to 0.
        delta_x: f64 = 0,
        delta_y: f64 = 0,

        /// Offset from the left edge
        offset_x: i32,
        /// Offset from the top edge
        offset_y: i32,
    },
    resize: struct {
        view: *View,

        delta_x: f64 = 0,
        delta_y: f64 = 0,

        /// Total x/y movement of the pointer device since the start of the resize,
        /// clamped to the bounds of the resize as defined by the view min/max
        /// dimensions and output dimensions.
        /// This is not directly tied to the rendered cursor position.
        x: i32 = 0,
        y: i32 = 0,

        /// Resize edges, maximum of 2 are set and they may not be opposing edges.
        edges: wlr.Edges,
        /// Offset from the left or right edge
        offset_x: i32,
        /// Offset from the top or bottom edge
        offset_y: i32,

        initial_width: u31,
        initial_height: u31,
    },
};

const default_size = 24;

const LayoutPoint = struct {
    lx: f64,
    ly: f64,
};

const log = std.log.scoped(.cursor);

/// Current cursor mode as well as any state needed to implement that mode
mode: Mode = .passthrough,

/// Set to whatever the current mode is when a transaction is started.
/// This is necessary to handle termination of move/resize modes properly
/// since the termination is not complete until a transaction completes and
/// View.resizeUpdatePosition() is called.
inflight_mode: Mode = .passthrough,

seat: *Seat,
wlr_cursor: *wlr.Cursor,

/// Xcursor manager for the currently configured Xcursor theme.
xcursor_manager: *wlr.XcursorManager,
/// Name of the current Xcursor shape, or null if a client has configured a
/// surface to be used as the cursor shape instead.
xcursor_name: ?[*:0]const u8 = null,

/// Number of distinct buttons currently pressed
pressed_count: u32 = 0,

hide_cursor_timer: *wl.EventSource,

hidden: bool = false,
may_need_warp: bool = false,

/// The pointer constraint for the surface that currently has keyboard focus, if any.
/// This constraint is not necessarily active, activation only occurs once the cursor
/// has been moved inside the constraint region.
constraint: ?*PointerConstraint = null,

/// View under the cursor, defined by view geometry rather than input region
focus_follows_cursor_target: ?*View = null,

/// Keeps track of the last known location of all touch points in layout coordinates.
/// This information is necessary for proper touch dnd support if there are multiple touch points.
touch_points: std.AutoHashMapUnmanaged(i32, LayoutPoint) = .{},

axis: wl.Listener(*wlr.Pointer.event.Axis) = wl.Listener(*wlr.Pointer.event.Axis).init(handleAxis),
frame: wl.Listener(*wlr.Cursor) = wl.Listener(*wlr.Cursor).init(handleFrame),
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

touch_down: wl.Listener(*wlr.Touch.event.Down) =
    wl.Listener(*wlr.Touch.event.Down).init(handleTouchDown),
touch_motion: wl.Listener(*wlr.Touch.event.Motion) =
    wl.Listener(*wlr.Touch.event.Motion).init(handleTouchMotion),
touch_up: wl.Listener(*wlr.Touch.event.Up) =
    wl.Listener(*wlr.Touch.event.Up).init(handleTouchUp),
touch_cancel: wl.Listener(*wlr.Touch.event.Cancel) =
    wl.Listener(*wlr.Touch.event.Cancel).init(handleTouchCancel),
touch_frame: wl.Listener(void) = wl.Listener(void).init(handleTouchFrame),

tablet_tool_axis: wl.Listener(*wlr.Tablet.event.Axis) =
    wl.Listener(*wlr.Tablet.event.Axis).init(handleTabletToolAxis),
tablet_tool_proximity: wl.Listener(*wlr.Tablet.event.Proximity) =
    wl.Listener(*wlr.Tablet.event.Proximity).init(handleTabletToolProximity),
tablet_tool_tip: wl.Listener(*wlr.Tablet.event.Tip) =
    wl.Listener(*wlr.Tablet.event.Tip).init(handleTabletToolTip),
tablet_tool_button: wl.Listener(*wlr.Tablet.event.Button) =
    wl.Listener(*wlr.Tablet.event.Button).init(handleTabletToolButton),

pub fn init(cursor: *Cursor, seat: *Seat) !void {
    const wlr_cursor = try wlr.Cursor.create();
    errdefer wlr_cursor.destroy();
    wlr_cursor.attachOutputLayout(server.root.output_layout);

    // This is here so that cursor.xcursor_manager doesn't need to be an
    // optional pointer. This isn't optimal as it does a needless allocation,
    // but this is not a hot path.
    const xcursor_manager = try wlr.XcursorManager.create(null, default_size);
    errdefer xcursor_manager.destroy();

    const event_loop = server.wl_server.getEventLoop();
    cursor.* = .{
        .seat = seat,
        .wlr_cursor = wlr_cursor,
        .xcursor_manager = xcursor_manager,
        .hide_cursor_timer = try event_loop.addTimer(*Cursor, handleHideCursorTimeout, cursor),
    };
    errdefer cursor.hide_cursor_timer.remove();
    try cursor.hide_cursor_timer.timerUpdate(server.config.cursor_hide_timeout);
    try cursor.setTheme(null, null);

    // wlr_cursor *only* displays an image on screen. It does not move around
    // when the pointer moves. However, we can attach input devices to it, and
    // it will generate aggregate events for all of them. In these events, we
    // can choose how we want to process them, forwarding them to clients and
    // moving the cursor around.
    wlr_cursor.events.axis.add(&cursor.axis);
    wlr_cursor.events.button.add(&cursor.button);
    wlr_cursor.events.frame.add(&cursor.frame);
    wlr_cursor.events.motion_absolute.add(&cursor.motion_absolute);
    wlr_cursor.events.motion.add(&cursor.motion);
    wlr_cursor.events.swipe_begin.add(&cursor.swipe_begin);
    wlr_cursor.events.swipe_update.add(&cursor.swipe_update);
    wlr_cursor.events.swipe_end.add(&cursor.swipe_end);
    wlr_cursor.events.pinch_begin.add(&cursor.pinch_begin);
    wlr_cursor.events.pinch_update.add(&cursor.pinch_update);
    wlr_cursor.events.pinch_end.add(&cursor.pinch_end);
    seat.wlr_seat.events.request_set_cursor.add(&cursor.request_set_cursor);

    wlr_cursor.events.touch_down.add(&cursor.touch_down);
    wlr_cursor.events.touch_motion.add(&cursor.touch_motion);
    wlr_cursor.events.touch_up.add(&cursor.touch_up);
    wlr_cursor.events.touch_cancel.add(&cursor.touch_cancel);
    wlr_cursor.events.touch_frame.add(&cursor.touch_frame);

    wlr_cursor.events.tablet_tool_axis.add(&cursor.tablet_tool_axis);
    wlr_cursor.events.tablet_tool_proximity.add(&cursor.tablet_tool_proximity);
    wlr_cursor.events.tablet_tool_tip.add(&cursor.tablet_tool_tip);
    wlr_cursor.events.tablet_tool_button.add(&cursor.tablet_tool_button);
}

pub fn deinit(cursor: *Cursor) void {
    cursor.hide_cursor_timer.remove();
    cursor.xcursor_manager.destroy();
    cursor.wlr_cursor.destroy();
}

/// Set the cursor theme for the given seat, as well as the xwayland theme if
/// this is the default seat. Either argument may be null, in which case a
/// default will be used.
pub fn setTheme(cursor: *Cursor, theme: ?[*:0]const u8, _size: ?u32) !void {
    const size = _size orelse default_size;

    const xcursor_manager = try wlr.XcursorManager.create(theme, size);
    errdefer xcursor_manager.destroy();

    // If this cursor belongs to the default seat, set the xcursor environment
    // variables as well as the xwayland cursor theme.
    if (cursor.seat == server.input_manager.defaultSeat()) {
        const size_str = try std.fmt.allocPrintZ(util.gpa, "{}", .{size});
        defer util.gpa.free(size_str);
        if (c.setenv("XCURSOR_SIZE", size_str.ptr, 1) < 0) return error.OutOfMemory;
        if (theme) |t| if (c.setenv("XCURSOR_THEME", t, 1) < 0) return error.OutOfMemory;

        if (build_options.xwayland) {
            if (server.xwayland) |xwayland| {
                try xcursor_manager.load(1);
                const wlr_xcursor = xcursor_manager.getXcursor("default", 1).?;
                const image = wlr_xcursor.images[0];
                xwayland.setCursor(
                    image.buffer,
                    image.width * 4,
                    image.width,
                    image.height,
                    @intCast(image.hotspot_x),
                    @intCast(image.hotspot_y),
                );
            }
        }
    }

    // Everything fallible is now done so the the old xcursor_manager can be destroyed.
    cursor.xcursor_manager.destroy();
    cursor.xcursor_manager = xcursor_manager;

    if (cursor.xcursor_name) |name| {
        cursor.setXcursor(name);
    }
}

pub fn setXcursor(cursor: *Cursor, name: [*:0]const u8) void {
    cursor.wlr_cursor.setXcursor(cursor.xcursor_manager, name);
    cursor.xcursor_name = name;
}

fn clearFocus(cursor: *Cursor) void {
    cursor.setXcursor("default");
    cursor.seat.wlr_seat.pointerNotifyClearFocus();
}

/// Axis event is a scroll wheel or similiar
fn handleAxis(listener: *wl.Listener(*wlr.Pointer.event.Axis), event: *wlr.Pointer.event.Axis) void {
    const cursor = @fieldParentPtr(Cursor, "axis", listener);

    cursor.seat.handleActivity();
    cursor.unhide();

    // Notify the client with pointer focus of the axis event.
    cursor.seat.wlr_seat.pointerNotifyAxis(
        event.time_msec,
        event.orientation,
        event.delta,
        event.delta_discrete,
        event.source,
    );
}

fn handleButton(listener: *wl.Listener(*wlr.Pointer.event.Button), event: *wlr.Pointer.event.Button) void {
    const cursor = @fieldParentPtr(Cursor, "button", listener);

    cursor.seat.handleActivity();
    cursor.unhide();

    if (event.state == .released) {
        assert(cursor.pressed_count > 0);
        cursor.pressed_count -= 1;
        if (cursor.pressed_count == 0 and cursor.mode != .passthrough) {
            log.debug("leaving {s} mode", .{@tagName(cursor.mode)});

            switch (cursor.mode) {
                .passthrough => unreachable,
                .down => {
                    // If we were in down mode, we need pass along the release event
                    _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
                },
                .move => {},
                .resize => |data| data.view.pending.resizing = false,
            }

            cursor.mode = .passthrough;
            cursor.passthrough(event.time_msec);

            server.root.applyPending();
        } else {
            _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
        }
        return;
    }

    assert(event.state == .pressed);
    cursor.pressed_count += 1;

    if (cursor.pressed_count > 1) {
        _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
        return;
    }

    if (server.root.at(cursor.wlr_cursor.x, cursor.wlr_cursor.y)) |result| {
        if (result.data == .view and cursor.handlePointerMapping(event, result.data.view)) {
            // If a mapping is triggered don't send events to clients.
            return;
        }

        cursor.updateKeyboardFocus(result);

        _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);

        if (result.surface != null) {
            cursor.mode = .{
                .down = .{
                    .lx = cursor.wlr_cursor.x,
                    .ly = cursor.wlr_cursor.y,
                    .sx = result.sx,
                    .sy = result.sy,
                },
            };
        }
    } else {
        cursor.updateOutputFocus(cursor.wlr_cursor.x, cursor.wlr_cursor.y);
    }

    server.root.applyPending();
}

/// Requires a call to Root.applyPending()
fn updateKeyboardFocus(cursor: Cursor, result: Root.AtResult) void {
    switch (result.data) {
        .view => |view| {
            cursor.seat.focus(view);
        },
        .layer_surface => |layer_surface| {
            cursor.seat.focusOutput(layer_surface.output);
            // If a keyboard inteactive layer surface has been clicked on,
            // give it keyboard focus.
            if (layer_surface.wlr_layer_surface.current.keyboard_interactive != .none) {
                cursor.seat.setFocusRaw(.{ .layer = layer_surface });
            }
        },
        .lock_surface => |lock_surface| {
            assert(server.lock_manager.state != .unlocked);
            cursor.seat.setFocusRaw(.{ .lock_surface = lock_surface });
        },
        .override_redirect => |override_redirect| {
            assert(server.lock_manager.state != .locked);
            override_redirect.focusIfDesired();
        },
    }
}

/// Focus the output at the given layout coordinates, if any
/// Requires a call to Root.applyPending()
fn updateOutputFocus(cursor: Cursor, lx: f64, ly: f64) void {
    if (server.root.output_layout.outputAt(lx, ly)) |wlr_output| {
        const output: *Output = @ptrFromInt(wlr_output.data);
        cursor.seat.focusOutput(output);
    }
}

fn handlePinchBegin(
    listener: *wl.Listener(*wlr.Pointer.event.PinchBegin),
    event: *wlr.Pointer.event.PinchBegin,
) void {
    const cursor = @fieldParentPtr(Cursor, "pinch_begin", listener);
    server.input_manager.pointer_gestures.sendPinchBegin(
        cursor.seat.wlr_seat,
        event.time_msec,
        event.fingers,
    );
}

fn handlePinchUpdate(
    listener: *wl.Listener(*wlr.Pointer.event.PinchUpdate),
    event: *wlr.Pointer.event.PinchUpdate,
) void {
    const cursor = @fieldParentPtr(Cursor, "pinch_update", listener);
    server.input_manager.pointer_gestures.sendPinchUpdate(
        cursor.seat.wlr_seat,
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
    const cursor = @fieldParentPtr(Cursor, "pinch_end", listener);
    server.input_manager.pointer_gestures.sendPinchEnd(
        cursor.seat.wlr_seat,
        event.time_msec,
        event.cancelled,
    );
}

fn handleSwipeBegin(
    listener: *wl.Listener(*wlr.Pointer.event.SwipeBegin),
    event: *wlr.Pointer.event.SwipeBegin,
) void {
    const cursor = @fieldParentPtr(Cursor, "swipe_begin", listener);
    server.input_manager.pointer_gestures.sendSwipeBegin(
        cursor.seat.wlr_seat,
        event.time_msec,
        event.fingers,
    );
}

fn handleSwipeUpdate(
    listener: *wl.Listener(*wlr.Pointer.event.SwipeUpdate),
    event: *wlr.Pointer.event.SwipeUpdate,
) void {
    const cursor = @fieldParentPtr(Cursor, "swipe_update", listener);
    server.input_manager.pointer_gestures.sendSwipeUpdate(
        cursor.seat.wlr_seat,
        event.time_msec,
        event.dx,
        event.dy,
    );
}

fn handleSwipeEnd(
    listener: *wl.Listener(*wlr.Pointer.event.SwipeEnd),
    event: *wlr.Pointer.event.SwipeEnd,
) void {
    const cursor = @fieldParentPtr(Cursor, "swipe_end", listener);
    server.input_manager.pointer_gestures.sendSwipeEnd(
        cursor.seat.wlr_seat,
        event.time_msec,
        event.cancelled,
    );
}

fn handleTouchDown(
    listener: *wl.Listener(*wlr.Touch.event.Down),
    event: *wlr.Touch.event.Down,
) void {
    const cursor = @fieldParentPtr(Cursor, "touch_down", listener);

    cursor.seat.handleActivity();

    var lx: f64 = undefined;
    var ly: f64 = undefined;
    cursor.wlr_cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);

    cursor.touch_points.putNoClobber(util.gpa, event.touch_id, .{ .lx = lx, .ly = ly }) catch {
        log.err("out of memory", .{});
        return;
    };

    if (server.root.at(lx, ly)) |result| {
        cursor.updateKeyboardFocus(result);

        if (result.surface) |surface| {
            _ = cursor.seat.wlr_seat.touchNotifyDown(
                surface,
                event.time_msec,
                event.touch_id,
                result.sx,
                result.sy,
            );
        }
    } else {
        cursor.updateOutputFocus(lx, ly);
    }

    server.root.applyPending();
}

fn handleTouchMotion(
    listener: *wl.Listener(*wlr.Touch.event.Motion),
    event: *wlr.Touch.event.Motion,
) void {
    const cursor = @fieldParentPtr(Cursor, "touch_motion", listener);

    cursor.seat.handleActivity();

    if (cursor.touch_points.getPtr(event.touch_id)) |point| {
        cursor.wlr_cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &point.lx, &point.ly);

        cursor.updateDragIcons();

        if (server.root.at(point.lx, point.ly)) |result| {
            cursor.seat.wlr_seat.touchNotifyMotion(event.time_msec, event.touch_id, result.sx, result.sy);
        }
    }
}

fn handleTouchUp(
    listener: *wl.Listener(*wlr.Touch.event.Up),
    event: *wlr.Touch.event.Up,
) void {
    const cursor = @fieldParentPtr(Cursor, "touch_up", listener);

    cursor.seat.handleActivity();

    if (cursor.touch_points.remove(event.touch_id)) {
        cursor.seat.wlr_seat.touchNotifyUp(event.time_msec, event.touch_id);
    }
}

fn handleTouchCancel(
    listener: *wl.Listener(*wlr.Touch.event.Cancel),
    _: *wlr.Touch.event.Cancel,
) void {
    const cursor = @fieldParentPtr(Cursor, "touch_cancel", listener);

    cursor.seat.handleActivity();

    cursor.touch_points.clearRetainingCapacity();

    // We can't call touchNotifyCancel() from inside the loop over touch points as it also loops
    // over touch points and may destroy multiple touch points in a single call.
    //
    // What we should do here is `while (touch_points.first()) |point| cancel()` but since the
    // surface may be null we can't rely on the fact tha all touch points will be destroyed
    // and risk an infinite loop if the surface of any wlr_touch_point is null.
    //
    // This is all really silly and totally unnecessary since all touchNotifyCancel() does with
    // the surface argument is obtain a seat client and touch_point.seat_client is never null.
    // TODO(wlroots) clean this up after the wlroots MR fixing this is merged:
    // https://gitlab.freedesktop.org/wlroots/wlroots/-/merge_requests/4613

    // The upper bound of 32 comes from an implementation detail of libinput which uses
    // a 32-bit integer as a map to keep track of touch points.
    var surfaces: std.BoundedArray(*wlr.Surface, 32) = .{};
    {
        var it = cursor.seat.wlr_seat.touch_state.touch_points.iterator(.forward);
        while (it.next()) |touch_point| {
            if (touch_point.surface) |surface| {
                surfaces.append(surface) catch break;
            }
        }
    }

    for (surfaces.slice()) |surface| {
        cursor.seat.wlr_seat.touchNotifyCancel(surface);
    }
}

fn handleTouchFrame(listener: *wl.Listener(void)) void {
    const cursor = @fieldParentPtr(Cursor, "touch_frame", listener);

    cursor.seat.handleActivity();

    cursor.seat.wlr_seat.touchNotifyFrame();
}

fn handleTabletToolAxis(
    _: *wl.Listener(*wlr.Tablet.event.Axis),
    event: *wlr.Tablet.event.Axis,
) void {
    const device: *InputDevice = @ptrFromInt(event.device.data);
    const tablet = @fieldParentPtr(Tablet, "device", device);

    device.seat.handleActivity();

    const tool = TabletTool.get(device.seat.wlr_seat, event.tool) catch return;

    tool.axis(tablet, event);
}

fn handleTabletToolProximity(
    _: *wl.Listener(*wlr.Tablet.event.Proximity),
    event: *wlr.Tablet.event.Proximity,
) void {
    const device: *InputDevice = @ptrFromInt(event.device.data);
    const tablet = @fieldParentPtr(Tablet, "device", device);

    device.seat.handleActivity();

    const tool = TabletTool.get(device.seat.wlr_seat, event.tool) catch return;

    tool.proximity(tablet, event);
}

fn handleTabletToolTip(
    _: *wl.Listener(*wlr.Tablet.event.Tip),
    event: *wlr.Tablet.event.Tip,
) void {
    const device: *InputDevice = @ptrFromInt(event.device.data);
    const tablet = @fieldParentPtr(Tablet, "device", device);

    device.seat.handleActivity();

    const tool = TabletTool.get(device.seat.wlr_seat, event.tool) catch return;

    tool.tip(tablet, event);
}

fn handleTabletToolButton(
    _: *wl.Listener(*wlr.Tablet.event.Button),
    event: *wlr.Tablet.event.Button,
) void {
    const device: *InputDevice = @ptrFromInt(event.device.data);
    const tablet = @fieldParentPtr(Tablet, "device", device);

    device.seat.handleActivity();

    const tool = TabletTool.get(device.seat.wlr_seat, event.tool) catch return;

    tool.button(tablet, event);
}

/// Handle the mapping for the passed button if any. Returns true if there
/// was a mapping and the button was handled.
fn handlePointerMapping(cursor: *Cursor, event: *wlr.Pointer.event.Button, view: *View) bool {
    const wlr_keyboard = cursor.seat.wlr_seat.getKeyboard() orelse return false;
    const modifiers = wlr_keyboard.getModifiers();

    const fullscreen = view.current.fullscreen or view.pending.fullscreen;

    return for (server.config.modes.items[cursor.seat.mode_id].pointer_mappings.items) |mapping| {
        if (event.button == mapping.event_code and std.meta.eql(modifiers, mapping.modifiers)) {
            switch (mapping.action) {
                .move => if (!fullscreen) cursor.startMove(view),
                .resize => if (!fullscreen) cursor.startResize(view, null),
                .command => |args| {
                    cursor.seat.focus(view);
                    cursor.seat.runCommand(args);
                    // This is mildly inefficient as running the command may have already
                    // started a transaction. However we need to start one after the Seat.focus()
                    // call in the case where it didn't.
                    server.root.applyPending();
                },
            }
            break true;
        }
    } else false;
}

/// Frame events are sent after regular pointer events to group multiple
/// events together. For instance, two axis events may happen at the same
/// time, in which case a frame event won't be sent in between.
fn handleFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    const cursor = @fieldParentPtr(Cursor, "frame", listener);
    cursor.seat.wlr_seat.pointerNotifyFrame();
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
    const cursor = @fieldParentPtr(Cursor, "motion_absolute", listener);

    cursor.seat.handleActivity();

    var lx: f64 = undefined;
    var ly: f64 = undefined;
    cursor.wlr_cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);

    const dx = lx - cursor.wlr_cursor.x;
    const dy = ly - cursor.wlr_cursor.y;
    cursor.processMotion(event.device, event.time_msec, dx, dy, dx, dy);
}

/// This event is forwarded by the cursor when a pointer emits a _relative_
/// pointer motion event (i.e. a delta)
fn handleMotion(
    listener: *wl.Listener(*wlr.Pointer.event.Motion),
    event: *wlr.Pointer.event.Motion,
) void {
    const cursor = @fieldParentPtr(Cursor, "motion", listener);

    cursor.seat.handleActivity();

    cursor.processMotion(event.device, event.time_msec, event.delta_x, event.delta_y, event.unaccel_dx, event.unaccel_dy);
}

fn handleRequestSetCursor(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
    event: *wlr.Seat.event.RequestSetCursor,
) void {
    // This event is rasied by the seat when a client provides a cursor image
    const cursor = @fieldParentPtr(Cursor, "request_set_cursor", listener);
    const focused_client = cursor.seat.wlr_seat.pointer_state.focused_client;

    // This can be sent by any client, so we check to make sure this one is
    // actually has pointer focus first.
    if (focused_client == event.seat_client) {
        // Once we've vetted the client, we can tell the cursor to use the
        // provided surface as the cursor image. It will set the hardware cursor
        // on the output that it's currently on and continue to do so as the
        // cursor moves between outputs.
        log.debug("focused client set cursor", .{});
        cursor.wlr_cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
        cursor.xcursor_name = null;
    }
}

pub fn hide(cursor: *Cursor) void {
    if (cursor.pressed_count > 0) return;
    cursor.hidden = true;
    cursor.wlr_cursor.unsetImage();
    cursor.xcursor_name = null;
    cursor.seat.wlr_seat.pointerNotifyClearFocus();
    cursor.hide_cursor_timer.timerUpdate(0) catch {
        log.err("failed to update cursor hide timeout", .{});
    };
}

pub fn unhide(cursor: *Cursor) void {
    cursor.hide_cursor_timer.timerUpdate(server.config.cursor_hide_timeout) catch {
        log.err("failed to update cursor hide timeout", .{});
    };
    if (!cursor.hidden) return;
    cursor.hidden = false;
    cursor.updateState();
}

fn handleHideCursorTimeout(cursor: *Cursor) c_int {
    log.debug("hide cursor timeout", .{});
    cursor.hide();
    return 0;
}

pub fn startMove(cursor: *Cursor, view: *View) void {
    // Guard against assertion in enterMode()
    if (view.current.output == null) return;

    if (cursor.constraint) |constraint| {
        if (constraint.state == .active) constraint.deactivate();
    }

    const new_mode: Mode = .{ .move = .{
        .view = view,
        .offset_x = @as(i32, @intFromFloat(cursor.wlr_cursor.x)) - view.current.box.x,
        .offset_y = @as(i32, @intFromFloat(cursor.wlr_cursor.y)) - view.current.box.y,
    } };
    cursor.enterMode(new_mode, view, "move");
}

pub fn startResize(cursor: *Cursor, view: *View, proposed_edges: ?wlr.Edges) void {
    // Guard against assertions in computeEdges() and enterMode()
    if (view.current.output == null) return;

    if (cursor.constraint) |constraint| {
        if (constraint.state == .active) constraint.deactivate();
    }

    const edges = blk: {
        if (proposed_edges) |edges| {
            if (edges.top or edges.bottom or edges.left or edges.right) {
                break :blk edges;
            }
        }
        break :blk cursor.computeEdges(view);
    };

    const box = &view.current.box;
    const lx: i32 = @intFromFloat(cursor.wlr_cursor.x);
    const ly: i32 = @intFromFloat(cursor.wlr_cursor.y);
    const offset_x = if (edges.left) lx - box.x else box.x + box.width - lx;
    const offset_y = if (edges.top) ly - box.y else box.y + box.height - ly;

    view.pending.resizing = true;

    const new_mode: Mode = .{ .resize = .{
        .view = view,
        .edges = edges,
        .offset_x = offset_x,
        .offset_y = offset_y,
        .initial_width = @intCast(box.width),
        .initial_height = @intCast(box.height),
    } };
    cursor.enterMode(new_mode, view, wlr.Xcursor.getResizeName(edges));
}

fn computeEdges(cursor: *const Cursor, view: *const View) wlr.Edges {
    const min_handle_size = 20;
    const box = &view.current.box;

    var output_box: wlr.Box = undefined;
    server.root.output_layout.getBox(view.current.output.?.wlr_output, &output_box);

    const sx = @as(i32, @intFromFloat(cursor.wlr_cursor.x)) - output_box.x - box.x;
    const sy = @as(i32, @intFromFloat(cursor.wlr_cursor.y)) - output_box.y - box.y;

    var edges: wlr.Edges = .{};

    if (box.width > min_handle_size * 2) {
        const handle = @max(min_handle_size, @divFloor(box.width, 5));
        if (sx < handle) {
            edges.left = true;
        } else if (sx > box.width - handle) {
            edges.right = true;
        }
    }

    if (box.height > min_handle_size * 2) {
        const handle = @max(min_handle_size, @divFloor(box.height, 5));
        if (sy < handle) {
            edges.top = true;
        } else if (sy > box.height - handle) {
            edges.bottom = true;
        }
    }

    if (!edges.top and !edges.bottom and !edges.left and !edges.right) {
        return .{ .bottom = true, .right = true };
    } else {
        return edges;
    }
}

fn enterMode(cursor: *Cursor, mode: Mode, view: *View, xcursor_name: [*:0]const u8) void {
    assert(cursor.mode == .passthrough or cursor.mode == .down);
    assert(mode == .move or mode == .resize);

    log.debug("enter {s} cursor mode", .{@tagName(mode)});

    cursor.mode = mode;

    cursor.seat.focus(view);

    if (view.current.output.?.layout != null) {
        view.float_box = view.current.box;
        view.pending.float = true;
    }

    cursor.seat.wlr_seat.pointerNotifyClearFocus();
    cursor.setXcursor(xcursor_name);

    server.root.applyPending();
}

fn processMotion(cursor: *Cursor, device: *wlr.InputDevice, time: u32, delta_x: f64, delta_y: f64, unaccel_dx: f64, unaccel_dy: f64) void {
    cursor.unhide();

    server.input_manager.relative_pointer_manager.sendRelativeMotion(
        cursor.seat.wlr_seat,
        @as(u64, time) * 1000,
        delta_x,
        delta_y,
        unaccel_dx,
        unaccel_dy,
    );

    var dx: f64 = delta_x;
    var dy: f64 = delta_y;

    if (cursor.constraint) |constraint| {
        if (constraint.state == .active) {
            switch (constraint.wlr_constraint.type) {
                .locked => return,
                .confined => constraint.confine(&dx, &dy),
            }
        }
    }

    switch (cursor.mode) {
        .passthrough, .down => {
            cursor.wlr_cursor.move(device, dx, dy);

            switch (cursor.mode) {
                .passthrough => {
                    cursor.checkFocusFollowsCursor();
                    cursor.passthrough(time);
                },
                .down => |data| {
                    cursor.seat.wlr_seat.pointerNotifyMotion(
                        time,
                        data.sx + (cursor.wlr_cursor.x - data.lx),
                        data.sy + (cursor.wlr_cursor.y - data.ly),
                    );
                },
                else => unreachable,
            }

            cursor.updateDragIcons();

            if (cursor.constraint) |constraint| {
                constraint.maybeActivate();
            }
        },
        .move => |*data| {
            dx += data.delta_x;
            dy += data.delta_y;
            data.delta_x = dx - @trunc(dx);
            data.delta_y = dy - @trunc(dy);

            data.view.pending.move(@intFromFloat(dx), @intFromFloat(dy));

            server.root.applyPending();
        },
        .resize => |*data| {
            dx += data.delta_x;
            dy += data.delta_y;
            data.delta_x = dx - @trunc(dx);
            data.delta_y = dy - @trunc(dy);

            data.x += @intFromFloat(dx);
            data.y += @intFromFloat(dy);

            // Modify width/height of the pending box, taking constraints into account
            // The x/y coordinates of the view will be adjusted as needed in View.resizeCommit()
            // based on the dimensions actually committed by the client.
            const border_width = if (data.view.pending.ssd) server.config.border_width else 0;

            const output = data.view.current.output orelse {
                data.view.pending.resizing = false;

                cursor.mode = .passthrough;
                cursor.passthrough(time);

                server.root.applyPending();
                return;
            };

            var output_width: i32 = undefined;
            var output_height: i32 = undefined;
            output.wlr_output.effectiveResolution(&output_width, &output_height);

            const constraints = &data.view.constraints;
            const box = &data.view.pending.box;

            if (data.edges.left) {
                const x2 = box.x + box.width;
                box.width = data.initial_width - data.x;
                box.width = @max(box.width, constraints.min_width);
                box.width = @min(box.width, constraints.max_width);
                box.width = @min(box.width, x2 - border_width);
                data.x = data.initial_width - box.width;
            } else if (data.edges.right) {
                box.width = data.initial_width + data.x;
                box.width = @max(box.width, constraints.min_width);
                box.width = @min(box.width, constraints.max_width);
                box.width = @min(box.width, output_width - border_width - box.x);
                data.x = box.width - data.initial_width;
            }

            if (data.edges.top) {
                const y2 = box.y + box.height;
                box.height = data.initial_height - data.y;
                box.height = @max(box.height, constraints.min_height);
                box.height = @min(box.height, constraints.max_height);
                box.height = @min(box.height, y2 - border_width);
                data.y = data.initial_height - box.height;
            } else if (data.edges.bottom) {
                box.height = data.initial_height + data.y;
                box.height = @max(box.height, constraints.min_height);
                box.height = @min(box.height, constraints.max_height);
                box.height = @min(box.height, output_height - border_width - box.y);
                data.y = box.height - data.initial_height;
            }

            server.root.applyPending();
        },
    }
}

pub fn checkFocusFollowsCursor(cursor: *Cursor) void {
    // Don't do focus-follows-cursor if a pointer drag is in progress as focus
    // change can't occur.
    if (cursor.seat.drag == .pointer) return;
    if (server.config.focus_follows_cursor == .disabled) return;

    const last_target = cursor.focus_follows_cursor_target;
    cursor.updateFocusFollowsCursorTarget();
    if (cursor.focus_follows_cursor_target) |view| {
        // In .normal mode, only entering a view changes focus
        if (server.config.focus_follows_cursor == .normal and
            last_target == view) return;
        if (cursor.seat.focused != .view or cursor.seat.focused.view != view) {
            if (view.current.output) |output| {
                cursor.seat.focusOutput(output);
                cursor.seat.focus(view);
                server.root.applyPending();
            }
        }
    } else {
        // The output doesn't contain any views, just focus the output.
        cursor.updateOutputFocus(cursor.wlr_cursor.x, cursor.wlr_cursor.y);
    }
}

fn updateFocusFollowsCursorTarget(cursor: *Cursor) void {
    if (server.root.at(cursor.wlr_cursor.x, cursor.wlr_cursor.y)) |result| {
        switch (result.data) {
            .view => |view| {
                // Some windows have an input region bigger than their window
                // geometry, we only want to update this when the cursor
                // properly enters the window (the box that we draw borders around)
                // in order to avoid clashes with cursor warping on focus change.
                if (view.current.output) |output| {
                    var output_layout_box: wlr.Box = undefined;
                    server.root.output_layout.getBox(output.wlr_output, &output_layout_box);

                    const cursor_ox = cursor.wlr_cursor.x - @as(f64, @floatFromInt(output_layout_box.x));
                    const cursor_oy = cursor.wlr_cursor.y - @as(f64, @floatFromInt(output_layout_box.y));
                    if (view.current.box.containsPoint(cursor_ox, cursor_oy)) {
                        cursor.focus_follows_cursor_target = view;
                    }
                }
            },
            .layer_surface, .lock_surface => {
                cursor.focus_follows_cursor_target = null;
            },
            .override_redirect => {
                assert(build_options.xwayland);
                assert(server.xwayland != null);
                cursor.focus_follows_cursor_target = null;
            },
        }
    } else {
        // The cursor is not above any view
        cursor.focus_follows_cursor_target = null;
    }
}

/// Handle potential change in location of views on the output, as well as
/// the target view of a cursor operation potentially being moved to a non-visible tag,
/// becoming fullscreen, etc.
pub fn updateState(cursor: *Cursor) void {
    if (cursor.may_need_warp) {
        cursor.warp();
    }

    if (cursor.constraint) |constraint| {
        constraint.updateState();
    }

    switch (cursor.mode) {
        .passthrough => {
            cursor.updateFocusFollowsCursorTarget();
            if (!cursor.hidden) {
                var now: os.timespec = undefined;
                os.clock_gettime(os.CLOCK.MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
                const msec: u32 = @intCast(now.tv_sec * std.time.ms_per_s +
                    @divTrunc(now.tv_nsec, std.time.ns_per_ms));
                cursor.passthrough(msec);
            }
        },
        // TODO: Leave down mode if the target surface is no longer visible.
        .down => assert(!cursor.hidden),
        .move, .resize => {
            // Moving and resizing of views is handled through the transaction system. Therefore,
            // we must inspect the inflight_mode instead if a move or a resize is in progress.
            //
            // The cases when a move/resize is being started or ended and e.g. mode is resize
            // while inflight_mode is passthrough or mode is passthrough while inflight_mode
            // is resize shouldn't need any special handling.
            //
            // In the first case, a move/resize has been started along with a transaction but the
            // transaction hasn't been committed yet so there is nothing to do.
            //
            // In the second case, a move/resize has been terminated by the user but the
            // transaction carrying out the final size/position change is still inflight.
            // Therefore, the user already expects the cursor to be free from the view and
            // we should not warp it back to the fixed offset of the move/resize.
            switch (cursor.inflight_mode) {
                .passthrough, .down => {},
                inline .move, .resize => |data, mode| {
                    assert(!cursor.hidden);

                    // These conditions are checked in Root.applyPending()
                    const output = data.view.current.output orelse return;
                    assert(data.view.current.tags & output.current.tags != 0);
                    assert(data.view.current.float or output.layout == null);
                    assert(!data.view.current.fullscreen);

                    // Keep the cursor locked to the original offset from the edges of the view.
                    const box = &data.view.current.box;
                    const new_x: f64 = blk: {
                        if (mode == .move or data.edges.left) {
                            break :blk @floatFromInt(data.offset_x + box.x);
                        } else if (data.edges.right) {
                            break :blk @floatFromInt(box.x + box.width - data.offset_x);
                        } else {
                            break :blk cursor.wlr_cursor.x;
                        }
                    };
                    const new_y: f64 = blk: {
                        if (mode == .move or data.edges.top) {
                            break :blk @floatFromInt(data.offset_y + box.y);
                        } else if (data.edges.bottom) {
                            break :blk @floatFromInt(box.y + box.height - data.offset_y);
                        } else {
                            break :blk cursor.wlr_cursor.y;
                        }
                    };

                    cursor.wlr_cursor.warpClosest(null, new_x, new_y);
                },
            }
        },
    }
}

/// Pass an event on to the surface under the cursor, if any.
fn passthrough(cursor: *Cursor, time: u32) void {
    assert(cursor.mode == .passthrough);

    if (server.root.at(cursor.wlr_cursor.x, cursor.wlr_cursor.y)) |result| {
        if (result.data == .lock_surface) {
            assert(server.lock_manager.state != .unlocked);
        } else {
            assert(server.lock_manager.state != .locked);
        }

        if (result.surface) |surface| {
            cursor.seat.wlr_seat.pointerNotifyEnter(surface, result.sx, result.sy);
            cursor.seat.wlr_seat.pointerNotifyMotion(time, result.sx, result.sy);
            return;
        }
    }

    cursor.clearFocus();
}

fn warp(cursor: *Cursor) void {
    cursor.may_need_warp = false;

    const focused_output = cursor.seat.focused_output orelse return;

    // Warp pointer to center of the focused view/output (In layout coordinates) if enabled.
    var output_layout_box: wlr.Box = undefined;
    server.root.output_layout.getBox(focused_output.wlr_output, &output_layout_box);
    const target_box = switch (server.config.warp_cursor) {
        .disabled => return,
        .@"on-output-change" => output_layout_box,
        .@"on-focus-change" => switch (cursor.seat.focused) {
            .layer, .lock_surface, .none => output_layout_box,
            .view => |view| wlr.Box{
                .x = output_layout_box.x + view.current.box.x,
                .y = output_layout_box.y + view.current.box.y,
                .width = view.current.box.width,
                .height = view.current.box.height,
            },
            .override_redirect => |override_redirect| wlr.Box{
                .x = override_redirect.xwayland_surface.x,
                .y = override_redirect.xwayland_surface.y,
                .width = override_redirect.xwayland_surface.width,
                .height = override_redirect.xwayland_surface.height,
            },
        },
    };
    // Checking against the usable box here gives much better UX when, for example,
    // a status bar allows using the pointer to change tag/view focus.
    const usable_box = focused_output.usable_box;
    const usable_layout_box = wlr.Box{
        .x = output_layout_box.x + usable_box.x,
        .y = output_layout_box.y + usable_box.y,
        .width = usable_box.width,
        .height = usable_box.height,
    };
    if (!output_layout_box.containsPoint(cursor.wlr_cursor.x, cursor.wlr_cursor.y) or
        (usable_layout_box.containsPoint(cursor.wlr_cursor.x, cursor.wlr_cursor.y) and
        !target_box.containsPoint(cursor.wlr_cursor.x, cursor.wlr_cursor.y)))
    {
        const lx: f64 = @floatFromInt(target_box.x + @divTrunc(target_box.width, 2));
        const ly: f64 = @floatFromInt(target_box.y + @divTrunc(target_box.height, 2));
        if (!cursor.wlr_cursor.warp(null, lx, ly)) {
            log.err("failed to warp cursor on focus change", .{});
        }
    }
}

fn updateDragIcons(cursor: *Cursor) void {
    var it = server.root.drag_icons.children.iterator(.forward);
    while (it.next()) |node| {
        const icon = @as(*DragIcon, @ptrFromInt(node.data));

        if (icon.wlr_drag_icon.drag.seat == cursor.seat.wlr_seat) {
            icon.updatePosition(cursor);
        }
    }
}
