// SPDX-FileCopyrightText: © 2026 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const TouchGesturesSeat = @This();

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const TouchGesture = @import("TouchGesture.zig");
const Seat = @import("Seat.zig");

const log = std.log.scoped(.wm);

object: ?*river.TouchGesturesSeatV1 = null,

gestures: wl.list.Head(TouchGesture, .link),

active: union(enum) {
    none,
    gesture: *TouchGesture,
    /// Active gesture was destroyed by the wm.
    inert,
} = .none,

pub fn init(gseat: *TouchGesturesSeat) void {
    gseat.* = .{
        .gestures = undefined,
    };
    gseat.gestures.init();
}

pub fn createObject(
    gseat: *TouchGesturesSeat,
    client: *wl.Client,
    version: u32,
    id: u32,
) void {
    assert(gseat.object == null);
    gseat.object = river.TouchGesturesSeatV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    gseat.object.?.setHandler(*TouchGesturesSeat, handleRequest, handleDestroy, gseat);
}

pub fn makeInert(gseat: *TouchGesturesSeat) void {
    if (gseat.object) |object| {
        object.setHandler(?*anyopaque, handleRequestInert, null, null);
        handleDestroy(object, gseat);
    }
}

fn handleRequestInert(
    object: *river.TouchGesturesSeatV1,
    request: river.TouchGesturesSeatV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) object.destroy();
}

fn handleDestroy(_: *river.TouchGesturesSeatV1, gseat: *TouchGesturesSeat) void {
    while (gseat.gestures.first()) |gesture| gesture.destroy();
    gseat.object = null;
}

fn handleRequest(
    object: *river.TouchGesturesSeatV1,
    request: river.TouchGesturesSeatV1.Request,
    gseat: *TouchGesturesSeat,
) void {
    assert(gseat.object == object);
    switch (request) {
        .destroy => object.destroy(),
        .get_gesture => |args| {
            const seat: *Seat = @fieldParentPtr("touch_gestures", gseat);
            if (args.finger_count == 0) {
                object.postError(.invalid_finger_count, "finger_count must be greater than zero");
                return;
            }
            TouchGesture.create(
                seat,
                object.getClient(),
                object.getVersion(),
                args.id,
                args.finger_count,
            ) catch {
                object.getClient().postNoMemory();
                log.err("out of memory", .{});
                return;
            };
        },
    }
}

/// Returns true if touch input is eaten by an active gesture.
pub fn update(gseat: *TouchGesturesSeat) bool {
    const seat: *Seat = @fieldParentPtr("touch_gestures", gseat);
    switch (gseat.active) {
        .none => {
            const values = gseat.computeValues();

            var it = gseat.gestures.iterator(.forward);
            const gesture = while (it.next()) |gesture| {
                if (!gesture.requested.enabled) continue;
                if (gesture.finger_count != values.finger_count) continue;
                if (-values.dx < gesture.requested.threshold_left and values.dx < gesture.requested.threshold_right) continue;
                if (-values.dy < gesture.requested.threshold_up and values.dy < gesture.requested.threshold_down) continue;
                if (values.scale) |scale| {
                    if (scale > gesture.requested.threshold_in and scale < gesture.requested.threshold_out) continue;
                }
                break gesture;
            } else {
                return false;
            };

            gesture.start();
            gseat.active = .{ .gesture = gesture };

            seat.touchOpCancel();

            return true;
        },
        .gesture => |gesture| {
            if (seat.touch_points.count() == 0) {
                gesture.end();
            } else if (seat.touch_points.count() != gesture.sent.finger_count) {
                server.wm.dirtyWindowing();
            } else {
                server.wm.dirtyWindowingLazy();
            }
            return true;
        },
        .inert => {
            if (seat.touch_points.count() == 0) {
                gseat.active = .none;
            }
            return true;
        },
    }
}

pub fn manageStart(gseat: *TouchGesturesSeat) void {
    switch (gseat.active) {
        .none, .inert => {},
        .gesture => |gesture| {
            switch (gesture.scheduled.state_change) {
                .none, .start => {
                    if (gesture.scheduled.state_change == .start) {
                        gesture.object.sendStart();
                    }
                    const values = gseat.computeValues();
                    if (gesture.sent.finger_count != values.finger_count) {
                        gesture.object.sendFingerCount(values.finger_count);
                        gesture.sent.finger_count = values.finger_count;
                    }
                    gesture.object.sendDeltaMotion(@intFromFloat(values.dx), @intFromFloat(values.dy));
                    if (values.scale) |scale| gesture.object.sendScale(.fromDouble(scale));
                },
                .cancel, .end => {
                    switch (gesture.scheduled.state_change) {
                        .none, .start => unreachable,
                        .end => gesture.object.sendEnd(),
                        .cancel => gesture.object.sendCancel(),
                    }
                    gseat.active = .none;
                },
            }
            gesture.scheduled.state_change = .none;
        },
    }
}

const GestureValues = struct {
    finger_count: u32,
    dx: f64,
    dy: f64,
    scale: ?f64,
};

fn computeValues(gseat: *TouchGesturesSeat) GestureValues {
    const seat: *Seat = @fieldParentPtr("touch_gestures", gseat);
    const finger_count: u32 = @intCast(seat.touch_points.count());
    const count: f64 = finger_count;

    const cx, const cy, const cx_down, const cy_down = centroids: {
        var x_sum: f64 = 0;
        var y_sum: f64 = 0;
        var x_sum_down: f64 = 0;
        var y_sum_down: f64 = 0;
        for (seat.touch_points.values()) |touch_point| {
            x_sum += touch_point.lx;
            y_sum += touch_point.ly;
            x_sum_down += touch_point.lx_down;
            y_sum_down += touch_point.ly_down;
        }
        break :centroids .{
            x_sum / count,
            y_sum / count,
            x_sum_down / count,
            y_sum_down / count,
        };
    };

    const scale = scale: {
        if (count < 2) break :scale null;
        var sum: f64 = 0;
        var sum_down: f64 = 0;
        for (seat.touch_points.values()) |touch_point| {
            sum += math.hypot(touch_point.lx - cx, touch_point.ly - cy);
            sum_down += math.hypot(touch_point.lx_down - cx_down, touch_point.ly_down - cy_down);
        }
        const d = sum / count;
        const d_down = sum_down / count;
        break :scale d / d_down;
    };

    return .{
        .finger_count = finger_count,
        .dx = cx - cx_down,
        .dy = cy - cy_down,
        .scale = scale,
    };
}
