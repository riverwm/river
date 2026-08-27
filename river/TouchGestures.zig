// SPDX-FileCopyrightText: © 2026 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const TouchGestures = @This();

const std = @import("std");
const assert = std.debug.assert;
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");

const log = std.log.scoped(.wm);

global: *wl.Global,

server_destroy: wl.Listener(*wl.Server) = .init(handleServerDestroy),

pub fn init(gestures: *TouchGestures) !void {
    gestures.* = .{
        .global = try wl.Global.create(server.wl_server, river.TouchGesturesV1, 1, ?*anyopaque, null, bind),
    };
    server.wl_server.addDestroyListener(&gestures.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const gestures: *TouchGestures = @fieldParentPtr("server_destroy", listener);

    gestures.global.destroy();
}

fn bind(client: *wl.Client, _: ?*anyopaque, version: u32, id: u32) void {
    const object = river.TouchGesturesV1.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };

    object.setHandler(?*anyopaque, handleRequest, null, null);
}

fn handleRequest(
    object: *river.TouchGesturesV1,
    request: river.TouchGesturesV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => object.destroy(),
        .get_seat => |args| {
            // Since we make all river_seat_v1 objects inert when the active
            // window manager is destroyed, this check means that only the
            // active window manager can create a gestures seat.
            const seat_data = args.seat.getUserData() orelse return;
            const seat: *Seat = @ptrCast(@alignCast(seat_data));
            if (seat.touch_gestures.object != null) {
                object.postError(
                    .object_already_created,
                    "river_touch_gestures_seat_v1 already created",
                );
                return;
            }
            seat.touch_gestures.createObject(object.getClient(), object.getVersion(), args.id);
        },
    }
}
