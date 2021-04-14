// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020-2021 The River Developers
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
const mem = std.mem;

const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const wlr = @import("wlroots");

const util = @import("util.zig");

const Option = @import("Option.zig");
const Output = @import("Output.zig");
const OutputOption = @import("OutputOption.zig");
const Server = @import("Server.zig");

const log = std.log.scoped(.river_options);

server: *Server,
global: *wl.Global,
server_destroy: wl.Listener(*wl.Server) = wl.Listener(*wl.Server).init(handleServerDestroy),

options: wl.list.Head(Option, "link") = undefined,

pub fn init(self: *Self, server: *Server) !void {
    self.* = .{
        .server = server,
        .global = try wl.Global.create(server.wl_server, river.OptionsManagerV2, 1, *Self, self, bind),
    };
    self.options.init();
    server.wl_server.addDestroyListener(&self.server_destroy);

    try Option.create(self, "layout", .{ .string = null });
    try Option.create(self, "output_title", .{ .string = null });
}

pub fn createOutputOptions(self: *Self, output: *Output) !void {
    var it = self.options.iterator(.forward);
    while (it.next()) |option| try OutputOption.create(option, output);
}

pub fn destroyOutputOptions(self: *Self, output: *Output) void {
    var it = self.options.iterator(.forward);
    while (it.next()) |option| {
        if (option.getOutputOption(output)) |output_option| output_option.destroy();
    }
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), wl_server: *wl.Server) void {
    const self = @fieldParentPtr(Self, "server_destroy", listener);
    self.global.destroy();
    var it = self.options.safeIterator(.forward);
    while (it.next()) |option| option.destroy();
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) callconv(.C) void {
    const options_manager = river.OptionsManagerV2.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    options_manager.setHandler(*Self, handleRequest, null, self);
}

pub fn getOption(self: *Self, key: [:0]const u8) ?*Option {
    var it = self.options.iterator(.forward);
    while (it.next()) |option| {
        if (mem.eql(u8, option.key, key)) return option;
    } else return null;
}

fn handleRequest(
    options_manager: *river.OptionsManagerV2,
    request: river.OptionsManagerV2.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => options_manager.destroy(),

        .declare_int_option => |req| if (self.getOption(mem.span(req.key)) == null) {
            Option.create(self, req.key, .{ .int = req.value }) catch {
                options_manager.getClient().postNoMemory();
                return;
            };
        },
        .declare_uint_option => |req| if (self.getOption(mem.span(req.key)) == null) {
            Option.create(self, req.key, .{ .uint = req.value }) catch {
                options_manager.getClient().postNoMemory();
                return;
            };
        },
        .declare_string_option => |req| if (self.getOption(mem.span(req.key)) == null) {
            Option.create(self, req.key, .{ .string = req.value }) catch {
                options_manager.getClient().postNoMemory();
                return;
            };
        },
        .declare_fixed_option => |req| if (self.getOption(mem.span(req.key)) == null) {
            Option.create(self, req.key, .{ .fixed = req.value }) catch {
                options_manager.getClient().postNoMemory();
                return;
            };
        },

        .get_option_handle => |req| {
            const output = if (req.output) |wl_output| blk: {
                // Ignore if the wl_output is inert
                const wlr_output = wlr.Output.fromWlOutput(wl_output) orelse return;
                break :blk @intToPtr(*Output, wlr_output.data);
            } else null;

            const option = self.getOption(mem.span(req.key)) orelse {
                // There is no option with the requested key. In this case
                // all we do is send an undeclared event and wait for the
                // client to destroy the resource.
                const handle = river.OptionHandleV2.create(
                    options_manager.getClient(),
                    options_manager.getVersion(),
                    req.handle,
                ) catch {
                    options_manager.getClient().postNoMemory();
                    return;
                };
                handle.sendUndeclared();
                handle.setHandler(*Self, undeclaredHandleRequest, null, self);
                return;
            };

            const handle = river.OptionHandleV2.create(
                options_manager.getClient(),
                options_manager.getVersion(),
                req.handle,
            ) catch {
                options_manager.getClient().postNoMemory();
                return;
            };

            option.addHandle(output, handle);
        },

        .unset_option => |req| {
            // Ignore if the wl_output is inert
            const wlr_output = wlr.Output.fromWlOutput(req.output) orelse return;
            const output = @intToPtr(*Output, wlr_output.data);

            const option = self.getOption(mem.span(req.key)) orelse return;
            option.getOutputOption(output).?.unset();
        },
    }
}

fn undeclaredHandleRequest(
    handle: *river.OptionHandleV2,
    request: river.OptionHandleV2.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => handle.destroy(),
        .set_int_value,
        .set_uint_value,
        .set_fixed_value,
        .set_string_value,
        => {
            handle.postError(
                .request_while_undeclared,
                "a request other than destroy was made on a handle to an undeclared option",
            );
        },
    }
}
