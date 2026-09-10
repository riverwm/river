// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const TouchGesture = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");

const log = std.log.scoped(.input);

seat: *Seat,
object: *river.TouchGestureV1,

finger_count: u32,

scheduled: struct {
    state_change: enum {
        none,
        start,
        end,
        cancel,
    } = .none,
} = .{},
sent: struct {
    finger_count: u32 = 0,
} = .{},
requested: struct {
    enabled: bool = false,
    threshold_motion: i32 = 0,
    dir: river.TouchGestureV1.Direction = .none,
    dir_min_distance: i32 = 0,
    threshold_in: f64 = 1.0,
    threshold_out: f64 = 1.0,
    edge: river.TouchGestureV1.Edge = .none,
    edge_max_distance: i32 = 0,
} = .{},

/// Seat.gestures
link: wl.list.Link,

pub fn create(
    seat: *Seat,
    client: *wl.Client,
    version: u32,
    id: u32,
    finger_count: u32,
) !void {
    const gesture = try util.gpa.create(TouchGesture);
    errdefer util.gpa.destroy(gesture);

    const object = try river.TouchGestureV1.create(client, version, id);
    errdefer comptime unreachable;

    gesture.* = .{
        .seat = seat,
        .object = object,
        .finger_count = finger_count,
        .link = undefined,
    };
    object.setHandler(*TouchGesture, handleRequest, handleDestroy, gesture);

    seat.touch_gestures.gestures.append(gesture);
}

pub fn destroy(gesture: *TouchGesture) void {
    gesture.object.setHandler(?*anyopaque, handleRequestInert, null, null);
    handleDestroy(gesture.object, gesture);
}

fn handleRequestInert(
    object: *river.TouchGestureV1,
    request: river.TouchGestureV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) object.destroy();
}

fn handleDestroy(_: *river.TouchGestureV1, gesture: *TouchGesture) void {
    gesture.link.remove();
    if (gesture.seat.touch_gestures.active == gesture) {
        gesture.seat.touch_gestures.active = null;
    }
    util.gpa.destroy(gesture);
}

fn handleRequest(
    object: *river.TouchGestureV1,
    request: river.TouchGestureV1.Request,
    gesture: *TouchGesture,
) void {
    assert(gesture.object == object);
    switch (request) {
        .destroy => object.destroy(),
        .enable => {
            if (!server.wm.ensureWindowing()) return;
            gesture.requested.enabled = true;
        },
        .disable => {
            if (!server.wm.ensureWindowing()) return;
            gesture.requested.enabled = false;
        },
        .set_threshold_motion => |args| {
            if (!server.wm.ensureWindowing()) return;
            if (args.min_distance < 0) {
                object.postError(.invalid_distance, "min_distance arg must be >= 0");
                return;
            }
            gesture.requested.threshold_motion = args.min_distance;
        },
        .set_direction => |args| {
            if (!server.wm.ensureWindowing()) return;
            switch (args.direction) {
                .none, .up, .down, .left, .right => {},
                _ => {
                    object.postError(.invalid_direction, "invalid river_touch_gesture_v1.direction enum value");
                    return;
                },
            }
            if (args.min_distance < 0) {
                object.postError(.invalid_distance, "min_distance arg must be >= 0");
                return;
            }
            gesture.requested.dir = args.direction;
            gesture.requested.dir_min_distance = args.min_distance;
        },
        .set_threshold_scale => |args| {
            if (!server.wm.ensureWindowing()) return;
            gesture.requested.threshold_in = args.in.toDouble();
            gesture.requested.threshold_out = args.out.toDouble();
        },
        .set_edge => |args| {
            if (!server.wm.ensureWindowing()) return;
            switch (args.edge) {
                .none, .top, .bottom, .left, .right => {},
                _ => {
                    object.postError(.invalid_edge, "invalid river_touch_gesture_v1.edge enum value");
                    return;
                },
            }
            if (args.max_distance < 0) {
                object.postError(.invalid_distance, "max_distance arg must be >= 0");
                return;
            }
            gesture.requested.edge = args.edge;
            gesture.requested.edge_max_distance = args.max_distance;
        },
    }
}

pub fn start(gesture: *TouchGesture) void {
    // Input event processing should not continue after a state change
    // until that event is sent to the window manager in an update and acked.
    assert(gesture.scheduled.state_change == .none);
    gesture.scheduled.state_change = .start;
    server.wm.dirtyWindowing();
}

pub fn end(gesture: *TouchGesture) void {
    // Input event processing should not continue after a state change
    // until that event is sent to the window manager in an update and acked.
    assert(gesture.scheduled.state_change == .none);
    gesture.scheduled.state_change = .end;
    server.wm.dirtyWindowing();
}

pub fn cancel(gesture: *TouchGesture) void {
    // Input event processing should not continue after a state change
    // until that event is sent to the window manager in an update and acked.
    assert(gesture.scheduled.state_change == .none);
    gesture.scheduled.state_change = .cancel;
    server.wm.dirtyWindowing();
}
