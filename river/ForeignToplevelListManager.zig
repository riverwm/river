// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2023 The River Developers
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

const Self = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const ext = wayland.server.ext;
const log = std.log.scoped(.foreign_toplevel_list);

const server = &@import("main.zig").server;
const Server = @import("Server.zig");

global: *wl.Global,
instances: wl.list.Head(ext.ForeignToplevelListV1, null) = undefined,
server_destroy: wl.Listener(*wl.Server) = wl.Listener(*wl.Server).init(handleServerDestroy),

pub fn init(self: *Self) !void {
    self.* = .{
        .global = try wl.Global.create(server.wl_server, ext.ForeignToplevelListV1, 1, *Self, self, bind),
    };
    self.instances.init();
    server.wl_server.addDestroyListener(&self.server_destroy);
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    // TODO XXX go over all views
    const foreign_toplevel_list = ext.ForeignToplevelListV1.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    foreign_toplevel_list.setHandler(*Self, handleRequest, handleDestroy, self);
    self.instances.append(foreign_toplevel_list);

    var it = server.root.views.iterator(.forward);
    while (it.next()) |view| {
        const handle = ext.ForeignToplevelHandleV1.create(
            client,
            version,
            0,
        ) catch {
            client.postNoMemory();
            log.err("out of memory", .{});
            return;
        };
        foreign_toplevel_list.sendToplevel(handle);
        view.addForeignToplevelListHandle(handle);
    }
}

fn handleRequest(
    foreign_toplevel_list: *ext.ForeignToplevelListV1,
    request: ext.ForeignToplevelListV1.Request,
    _: *Self,
) void {
    switch (request) {
        .destroy => foreign_toplevel_list.destroy(),
        .stop => {},
    }
}

fn handleDestroy(
    foreign_toplevel_list: *ext.ForeignToplevelListV1,
    _: *Self,
) void {
    foreign_toplevel_list.getLink().remove();
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const self = @fieldParentPtr(Self, "server_destroy", listener);
    var it = self.instances.iterator(.forward);
    while (it.next()) |resource| {
        resource.destroy();
    }
    self.global.destroy();
}
