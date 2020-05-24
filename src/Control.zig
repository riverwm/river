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

const Command = @import("Command.zig");
const Log = @import("log.zig").Log;
const Server = @import("Server.zig");

const protocol_version = 1;

const implementation = c.struct_zriver_control_v1_interface{
    .run_command = runCommand,
};

server: *Server,
wl_global: *c.wl_global,

listen_display_destroy: c.wl_listener,

pub fn init(self: *Self, server: *Server) !void {
    self.server = server;
    self.wl_global = c.wl_global_create(
        server.wl_display,
        &c.zriver_control_v1_interface,
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
        &c.zriver_control_v1_interface,
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

fn runCommand(
    wl_client: ?*c.wl_client,
    wl_resource: ?*c.wl_resource,
    wl_array: ?*c.wl_array,
    callback_id: u32,
) callconv(.C) void {
    const self = @ptrCast(*Self, @alignCast(@alignOf(*Self), c.wl_resource_get_user_data(wl_resource)));
    const allocator = self.server.allocator;

    var args = std.ArrayList([]const u8).init(allocator);

    var i: usize = 0;
    const data = @ptrCast([*]const u8, wl_array.?.data);
    while (i < wl_array.?.size) {
        const slice = std.mem.spanZ(@ptrCast([*:0]const u8, &data[i]));
        args.append(std.mem.dupe(allocator, u8, slice) catch unreachable) catch unreachable;

        i += slice.len + 1;
    }

    const callback_resource = c.wl_resource_create(
        wl_client,
        &c.zriver_command_callback_v1_interface,
        protocol_version,
        callback_id,
    ) orelse {
        c.wl_client_post_no_memory(wl_client);
        return;
    };

    c.wl_resource_set_implementation(callback_resource, null, null, null);

    const command = Command.init(args.items, allocator) catch |err| {
        c.zriver_command_callback_v1_send_failure(
            callback_resource,
            switch (err) {
                Command.Error.NoCommand => "no command given",
                Command.Error.UnknownCommand => "unknown command",
                Command.Error.NotEnoughArguments => "not enough arguments",
                Command.Error.TooManyArguments => "too many arguments",
                Command.Error.Overflow => "value out of bounds",
                Command.Error.InvalidCharacter => "invalid character in argument",
                Command.Error.InvalidDirection => "invalid direction. Must be 'next' or 'previous'",
                Command.Error.OutOfMemory => unreachable,
            },
        );
        return;
    };
    c.zriver_command_callback_v1_send_success(callback_resource);
    command.run(self.server.input_manager.default_seat);
}
