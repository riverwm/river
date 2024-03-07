// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 - 2021 The River Developers
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

const LayoutManager = @This();

const std = @import("std");
const mem = std.mem;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Layout = @import("Layout.zig");
const Server = @import("Server.zig");
const Output = @import("Output.zig");

const log = std.log.scoped(.layout);

global: *wl.Global,
server_destroy: wl.Listener(*wl.Server) = wl.Listener(*wl.Server).init(handleServerDestroy),

pub fn init(layout_manager: *LayoutManager) !void {
    layout_manager.* = .{
        .global = try wl.Global.create(server.wl_server, river.LayoutManagerV3, 2, ?*anyopaque, null, bind),
    };

    server.wl_server.addDestroyListener(&layout_manager.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const layout_manager: *LayoutManager = @fieldParentPtr("server_destroy", listener);
    layout_manager.global.destroy();
}

fn bind(client: *wl.Client, _: ?*anyopaque, version: u32, id: u32) void {
    const layout_manager_v3 = river.LayoutManagerV3.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    layout_manager_v3.setHandler(?*anyopaque, handleRequest, null, null);
}

fn handleRequest(
    layout_manager_v3: *river.LayoutManagerV3,
    request: river.LayoutManagerV3.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => layout_manager_v3.destroy(),

        .get_layout => |req| {
            // Ignore if the output is inert
            const wlr_output = wlr.Output.fromWlOutput(req.output) orelse return;
            const output: *Output = @ptrFromInt(wlr_output.data);

            log.debug("bind layout '{s}' on output '{s}'", .{ req.namespace, output.wlr_output.name });

            Layout.create(
                layout_manager_v3.getClient(),
                layout_manager_v3.getVersion(),
                req.id,
                output,
                mem.sliceTo(req.namespace, 0),
            ) catch {
                layout_manager_v3.getClient().postNoMemory();
                log.err("out of memory", .{});
                return;
            };
        },
    }
}
