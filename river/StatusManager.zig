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

const StatusManager = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zriver = wayland.server.zriver;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const OutputStatus = @import("OutputStatus.zig");
const Seat = @import("Seat.zig");
const SeatStatus = @import("SeatStatus.zig");
const Server = @import("Server.zig");

const log = std.log.scoped(.river_status);

global: *wl.Global,

server_destroy: wl.Listener(*wl.Server) = wl.Listener(*wl.Server).init(handleServerDestroy),

pub fn init(status_manager: *StatusManager) !void {
    status_manager.* = .{
        .global = try wl.Global.create(server.wl_server, zriver.StatusManagerV1, 4, ?*anyopaque, null, bind),
    };

    server.wl_server.addDestroyListener(&status_manager.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const status_manager: *StatusManager = @fieldParentPtr("server_destroy", listener);
    status_manager.global.destroy();
}

fn bind(client: *wl.Client, _: ?*anyopaque, version: u32, id: u32) void {
    const status_manager_v1 = zriver.StatusManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    status_manager_v1.setHandler(?*anyopaque, handleRequest, null, null);
}

fn handleRequest(
    status_manager_v1: *zriver.StatusManagerV1,
    request: zriver.StatusManagerV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => status_manager_v1.destroy(),
        .get_river_output_status => |req| {
            // ignore if the output is inert
            const wlr_output = wlr.Output.fromWlOutput(req.output) orelse return;
            const output: *Output = @alignCast(@ptrCast(wlr_output.data));

            const resource = zriver.OutputStatusV1.create(
                status_manager_v1.getClient(),
                status_manager_v1.getVersion(),
                req.id,
            ) catch {
                status_manager_v1.getClient().postNoMemory();
                log.err("out of memory", .{});
                return;
            };

            output.status.add(resource, output);
        },
        .get_river_seat_status => |req| {
            // ignore if the seat is inert
            const wlr_seat = wlr.Seat.Client.fromWlSeat(req.seat) orelse return;
            const seat: *Seat = @alignCast(@ptrCast(wlr_seat.seat.data));

            const node = util.gpa.create(std.SinglyLinkedList(SeatStatus).Node) catch {
                status_manager_v1.getClient().postNoMemory();
                log.err("out of memory", .{});
                return;
            };

            const seat_status = zriver.SeatStatusV1.create(
                status_manager_v1.getClient(),
                status_manager_v1.getVersion(),
                req.id,
            ) catch {
                status_manager_v1.getClient().postNoMemory();
                util.gpa.destroy(node);
                log.err("out of memory", .{});
                return;
            };

            node.data.init(seat, seat_status);
            seat.status_trackers.prepend(node);
        },
    }
}
