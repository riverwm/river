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
const command = @import("command.zig");

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
        &c.zriver_control_v1_interface,
        @intCast(c_int, version),
        id,
    ) orelse {
        c.wl_client_post_no_memory(wl_client);
        return;
    };
    c.wl_resource_set_implementation(wl_resource, &implementation, self, null);
}

fn runCommand(
    wl_client: ?*c.wl_client,
    wl_resource: ?*c.wl_resource,
    wl_array: ?*c.wl_array,
    callback_id: u32,
) callconv(.C) void {
    const self = @ptrCast(*Self, @alignCast(@alignOf(*Self), c.wl_resource_get_user_data(wl_resource)));
    const allocator = self.server.allocator;
    const seat = self.server.input_manager.default_seat;

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    var i: usize = 0;
    const data = @ptrCast([*]const u8, wl_array.?.data);
    while (i < wl_array.?.size) {
        const slice = std.mem.spanZ(@ptrCast([*:0]const u8, &data[i]));
        args.append(slice) catch unreachable;

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

    var failure_message: []const u8 = undefined;
    command.run(allocator, seat, args.items, &failure_message) catch |err| {
        if (err == command.Error.CommandFailed) {
            defer allocator.free(failure_message);
            const out = std.cstr.addNullByte(allocator, failure_message) catch {
                c.zriver_command_callback_v1_send_failure(callback_resource, "out of memory");
                return;
            };
            defer allocator.free(out);
            c.zriver_command_callback_v1_send_failure(callback_resource, out);
        } else {
            c.zriver_command_callback_v1_send_failure(
                callback_resource,
                switch (err) {
                    command.Error.NoCommand => "no command given",
                    command.Error.UnknownCommand => "unknown command",
                    command.Error.NotEnoughArguments => "not enough arguments",
                    command.Error.TooManyArguments => "too many arguments",
                    command.Error.Overflow => "value out of bounds",
                    command.Error.InvalidCharacter => "invalid character in argument",
                    command.Error.InvalidDirection => "invalid direction. Must be 'next' or 'previous'",
                    command.Error.OutOfMemory => "out of memory",
                    command.Error.CommandFailed => unreachable,
                },
            );
        }
        return;
    };
    c.zriver_command_callback_v1_send_success(callback_resource);
}
