// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const XkbBindings = @This();

const std = @import("std");
const assert = std.debug.assert;
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");
const XkbBinding = @import("XkbBinding.zig");

const log = std.log.scoped(.wm);

global: *wl.Global,

server_destroy: wl.Listener(*wl.Server) = .init(handleServerDestroy),

pub fn init(bindings: *XkbBindings) !void {
    bindings.* = .{
        .global = try wl.Global.create(server.wl_server, river.XkbBindingsV1, 2, ?*anyopaque, null, bind),
    };
    server.wl_server.addDestroyListener(&bindings.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const bindings: *XkbBindings = @fieldParentPtr("server_destroy", listener);

    bindings.global.destroy();
}

fn bind(client: *wl.Client, _: ?*anyopaque, version: u32, id: u32) void {
    const object = river.XkbBindingsV1.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };

    object.setHandler(?*anyopaque, handleRequest, null, null);
}

fn handleRequest(
    object: *river.XkbBindingsV1,
    request: river.XkbBindingsV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => object.destroy(),
        .get_xkb_binding => |args| {
            const seat_data = args.seat.getUserData() orelse return;
            const seat: *Seat = @ptrCast(@alignCast(seat_data));
            XkbBinding.create(
                seat,
                object.getClient(),
                object.getVersion(),
                args.id,
                @enumFromInt(args.keysym),
                args.modifiers,
            ) catch {
                object.getClient().postNoMemory();
                log.err("out of memory", .{});
                return;
            };
        },
        .get_seat => |args| {
            const seat_data = args.seat.getUserData() orelse return;
            const seat: *Seat = @ptrCast(@alignCast(seat_data));
            if (seat.xkb_bindings_seat.object != null) {
                object.postError(
                    .object_already_created,
                    "river_xkb_bindings_seat_v1 already created",
                );
                return;
            }
            seat.xkb_bindings_seat.createObject(object.getClient(), object.getVersion(), args.id);
        },
    }
}
