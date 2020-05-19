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
const Server = @import("Server.zig");

const protocol_version = 1;

const implementation = c.struct_zriver_window_manager_v1_interface{
    .run_command = runCommand,
};

server: *Server,
wl_global: *c.wl_global,

listen_display_destroy: c.wl_listener,

pub fn init(self: *Self, server: *Server) !void {
    self.wl_global = c.wl_global_create(
        server.wl_display,
        &c.zriver_window_manager_v1_interface,
        protocol_version,
        self,
        bind,
    ) orelse return error.CantCreateRiverWindowManagementGlobal;

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
        &c.zriver_window_manager_v1_interface,
        @intCast(c_int, version),
        id,
    ) orelse {
        c.wl_client_post_no_memory(wl_client);
        return;
    };
    c.wl_resource_set_implementation(wl_resource, &implementation, self, resourceDestroy);
}

fn resourceDestroy(wl_resource: ?*c.wl_resource) callconv(.C) void {
    // TODO
}

fn runCommand(wl_client: ?*c.wl_client, wl_resource: ?*c.wl_resource, command: ?[*:0]const u8) callconv(.C) void {
    Log.Debug.log("command: {}", .{command});
}
