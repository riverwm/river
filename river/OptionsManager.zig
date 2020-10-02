// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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

const wayland = @import("wayland");
const wl = wayland.server.wl;
const zriver = wayland.server.zriver;

const wlr = @import("wlroots");

const util = @import("util.zig");

const Option = @import("Option.zig");
const Output = @import("Output.zig");
const Server = @import("Server.zig");

global: *wl.Global,
server_destroy: wl.Listener(*wl.Server) = wl.Listener(*wl.Server).init(handleServerDestroy),

options: wl.list.Head(Option, "link") = undefined,

pub fn init(self: *Self, server: *Server) !void {
    self.* = .{
        .global = try wl.Global.create(server.wl_server, zriver.OptionsManagerV1, 1, *Self, self, bind),
    };
    self.options.init();
    server.wl_server.addDestroyListener(&self.server_destroy);
}

pub fn handleOutputDestroy(self: *Self, output: *Output) void {
    var it = self.options.safeIterator(.forward);
    while (it.next()) |option| {
        if (option.output == output) option.destroy();
    }
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), wl_server: *wl.Server) void {
    const self = @fieldParentPtr(Self, "server_destroy", listener);
    self.global.destroy();
    var it = self.options.safeIterator(.forward);
    while (it.next()) |option| option.destroy();
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) callconv(.C) void {
    const options_manager = zriver.OptionsManagerV1.create(client, 1, id) catch {
        client.postNoMemory();
        return;
    };
    options_manager.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    options_manager: *zriver.OptionsManagerV1,
    request: zriver.OptionsManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => options_manager.destroy(),
        .get_option_handle => |req| {
            const output = if (req.output) |wl_output| blk: {
                // Ignore if the wl_output is inert
                const wlr_output = wlr.Output.fromWlOutput(wl_output) orelse return;
                break :blk @intToPtr(*Output, wlr_output.data);
            } else null;

            // Look for an existing Option, if not found create a new one
            var it = self.options.iterator(.forward);
            const option = while (it.next()) |option| {
                if (option.output == output and std.cstr.cmp(option.key, req.key) == 0) {
                    break option;
                }
            } else
                Option.create(self, output, req.key, .unset) catch {
                    options_manager.getClient().postNoMemory();
                    return;
                };

            const handle = zriver.OptionHandleV1.create(
                options_manager.getClient(),
                options_manager.getVersion(),
                req.handle,
            ) catch {
                options_manager.getClient().postNoMemory();
                return;
            };

            option.addHandle(handle);
        },
    }
}
