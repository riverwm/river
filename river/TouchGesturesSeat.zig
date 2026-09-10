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

active: ?*TouchGesture = null,

requested: struct {
    /// Arbitration timeout in milliseconds
    arbitration_timeout: u32 = 100,
} = .{},

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
    gseat.requested = .{};
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
        .set_arbitration_timeout => |args| {
            gseat.requested.arbitration_timeout = args.msec;
        },
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

/// Returns true if a gesture was activated and touch input should be eaten.
pub fn activate(gseat: *TouchGesturesSeat, mapping: *const wlr.Box) bool {
    assert(gseat.active == null);

    var touchscreen = mapping.*;
    if (touchscreen.empty()) {
        server.om.output_layout.getBox(null, &touchscreen);
    }

    const values = gseat.computeValues();

    var it = gseat.gestures.iterator(.forward);
    const gesture = while (it.next()) |gesture| {
        if (!gesture.requested.enabled) continue;
        if (gesture.finger_count != values.finger_count) continue;
        if (values.distance < gesture.requested.threshold_motion) continue;
        switch (gesture.requested.dir) {
            .none => {},
            .up => if (-values.dy < gesture.requested.dir_min_distance) continue,
            .down => if (values.dy < gesture.requested.dir_min_distance) continue,
            .left => if (-values.dx < gesture.requested.dir_min_distance) continue,
            .right => if (values.dx < gesture.requested.dir_min_distance) continue,
            _ => unreachable,
        }
        if (values.scale) |scale| {
            if (scale > gesture.requested.threshold_in and scale < gesture.requested.threshold_out) continue;
        }
        switch (gesture.requested.edge) {
            .none => {},
            .top => {
                if (values.cy_down < touchscreen.y or
                    values.cy_down > touchscreen.y + gesture.requested.edge_max_distance) continue;
            },
            .bottom => {
                if (values.cy_down > touchscreen.y + touchscreen.height or
                    values.cy_down < touchscreen.y + touchscreen.height - gesture.requested.edge_max_distance) continue;
            },
            .left => {
                if (values.cx_down < touchscreen.x or
                    values.cx_down > touchscreen.x + gesture.requested.edge_max_distance) continue;
            },
            .right => {
                if (values.cx_down > touchscreen.x + touchscreen.width or
                    values.cx_down < touchscreen.x + touchscreen.width - gesture.requested.edge_max_distance) continue;
            },
            _ => unreachable,
        }
        break gesture;
    } else {
        return false;
    };

    gesture.start();
    gseat.active = gesture;

    log.debug("touch gesture activated", .{});

    return true;
}

pub fn manageStart(gseat: *TouchGesturesSeat) void {
    if (gseat.active) |gesture| {
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
                gseat.active = null;
            },
        }
        gesture.scheduled.state_change = .none;
    }
}

const GestureValues = struct {
    finger_count: u32,
    distance: f64,
    /// Mean x coordinate of touch down events
    cx_down: f64,
    /// Mean y coordinate of touch down events
    cy_down: f64,
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

        const points = seat.touch_points.values();
        var xmin: f64 = points[0].lx;
        var xmax: f64 = points[0].lx;
        var ymin: f64 = points[0].ly;
        var ymax: f64 = points[0].ly;

        var xmin_down: f64 = points[0].lx_down;
        var xmax_down: f64 = points[0].lx_down;
        var ymin_down: f64 = points[0].ly_down;
        var ymax_down: f64 = points[0].ly_down;

        for (points) |touch_point| {
            xmin = @min(xmin, touch_point.lx);
            ymin = @min(ymin, touch_point.ly);
            xmax = @max(xmax, touch_point.lx);
            ymax = @max(ymax, touch_point.ly);

            xmin_down = @min(xmin_down, touch_point.lx_down);
            ymin_down = @min(ymin_down, touch_point.ly_down);
            xmax_down = @max(xmax_down, touch_point.lx_down);
            ymax_down = @max(ymax_down, touch_point.ly_down);
        }

        // Diagonal of the bounding box of all touch points
        const d = math.hypot(xmax - xmin, ymax - ymin);
        const d_down = math.hypot(xmax_down - xmin_down, ymax_down - ymin_down);
        break :scale d / d_down;
    };

    return .{
        .finger_count = finger_count,
        .distance = math.hypot(cx - cx_down, cy - cy_down),
        .cx_down = cx_down,
        .cy_down = cy_down,
        .dx = cx - cx_down,
        .dy = cy - cy_down,
        .scale = scale,
    };
}
