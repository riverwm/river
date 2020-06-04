// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
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

const std = @import("std");

const c = @import("c.zig");

const Log = @import("log.zig").Log;
const Output = @import("Output.zig");
const OutputStatus = @import("OutputStatus.zig");
const Seat = @import("Seat.zig");
const SeatStatus = @import("SeatStatus.zig");
const Server = @import("Server.zig");

const protocol_version = 1;

const implementation = c.struct_zriver_status_manager_v1_interface{
    .destroy = destroy,
    .get_river_output_status = getRiverOutputStatus,
    .get_river_seat_status = getRiverSeatStatus,
};

// TODO: remove this field, move allocator to util or something
server: *Server,
wl_global: *c.wl_global,

listen_display_destroy: c.wl_listener,

pub fn init(self: *Self, server: *Server) !void {
    self.server = server;
    self.wl_global = c.wl_global_create(
        server.wl_display,
        &c.zriver_status_manager_v1_interface,
        protocol_version,
        self,
        bind,
    ) orelse return error.CantCreateWlGlobal;

    self.listen_display_destroy.notify = handleDisplayDestroy;
    c.wl_display_add_destroy_listener(server.wl_display, &self.listen_display_destroy);
}

fn handleDisplayDestroy(wl_listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_display_destroy", wl_listener.?);
    c.wl_global_destroy(self.wl_global);
}

/// Called when a client binds our global
fn bind(wl_client: ?*c.wl_client, data: ?*c_void, version: u32, id: u32) callconv(.C) void {
    const self = @ptrCast(*Self, @alignCast(@alignOf(*Self), data));
    const wl_resource = c.wl_resource_create(
        wl_client,
        &c.zriver_status_manager_v1_interface,
        @intCast(c_int, version),
        id,
    ) orelse {
        c.wl_client_post_no_memory(wl_client);
        Log.Error.log("out of memory\n", .{});
        return;
    };
    c.wl_resource_set_implementation(wl_resource, &implementation, self, null);
}

fn destroy(wl_client: ?*c.wl_client, wl_resource: ?*c.wl_resource) callconv(.C) void {}

fn getRiverOutputStatus(
    wl_client: ?*c.wl_client,
    wl_resource: ?*c.wl_resource,
    new_id: u32,
    output_wl_resource: ?*c.wl_resource,
) callconv(.C) void {
    const self = @ptrCast(*Self, @alignCast(@alignOf(*Self), c.wl_resource_get_user_data(wl_resource)));
    // This can be null if the output is inert, in which case we ignore the request
    const wlr_output = c.wlr_output_from_resource(output_wl_resource) orelse return;
    const output = @ptrCast(*Output, @alignCast(@alignOf(*Output), wlr_output.*.data));
    const allocator = self.server.allocator;

    const node = allocator.create(std.SinglyLinkedList(OutputStatus).Node) catch {
        c.wl_client_post_no_memory(wl_client);
        Log.Error.log("out of memory\n", .{});
        return;
    };

    const output_status_resource = c.wl_resource_create(
        wl_client,
        &c.zriver_output_status_v1_interface,
        protocol_version,
        new_id,
    ) orelse {
        c.wl_client_post_no_memory(wl_client);
        Log.Error.log("out of memory\n", .{});
        return;
    };

    node.data.init(output, output_status_resource);
    output.status_trackers.prepend(node);
}

fn getRiverSeatStatus(
    wl_client: ?*c.wl_client,
    wl_resource: ?*c.wl_resource,
    new_id: u32,
    seat_wl_resource: ?*c.wl_resource,
) callconv(.C) void {
    const self = @ptrCast(*Self, @alignCast(@alignOf(*Self), c.wl_resource_get_user_data(wl_resource)));
    // This can be null if the seat is inert, in which case we ignore the request
    const wlr_seat_client = c.wlr_seat_client_from_resource(seat_wl_resource) orelse return;
    const seat = @ptrCast(*Seat, @alignCast(@alignOf(*Seat), wlr_seat_client.*.seat.*.data));
    const allocator = self.server.allocator;

    const node = allocator.create(std.SinglyLinkedList(SeatStatus).Node) catch {
        c.wl_client_post_no_memory(wl_client);
        Log.Error.log("out of memory\n", .{});
        return;
    };

    const seat_status_resource = c.wl_resource_create(
        wl_client,
        &c.zriver_seat_status_v1_interface,
        protocol_version,
        new_id,
    ) orelse {
        c.wl_client_post_no_memory(wl_client);
        Log.Error.log("out of memory\n", .{});
        return;
    };

    node.data.init(seat, seat_status_resource);
    seat.status_trackers.prepend(node);
}
