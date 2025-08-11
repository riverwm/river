// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2025 The River Developers
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
        .global = try wl.Global.create(server.wl_server, river.XkbBindingsV1, 1, ?*anyopaque, null, bind),
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
    }
}
