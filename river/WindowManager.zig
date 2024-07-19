// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2024 The River Developers
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

const WindowManager = @This();

const std = @import("std");
const assert = std.debug.assert;
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const log = std.log.scoped(.wm);

global: *wl.Global,
server_destroy: wl.Listener(*wl.Server) = wl.Listener(*wl.Server).init(handleServerDestroy),

/// The active window manager, if any.
wm_v1: ?*river.WindowManagerV1 = null,

pub fn init(wm: *WindowManager) !void {
    wm.* = .{
        .global = try wl.Global.create(server.wl_server, river.WindowManagerV1, 1, *WindowManager, wm, bind),
    };

    server.wl_server.addDestroyListener(&wm.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const wm: *WindowManager = @fieldParentPtr("server_destroy", listener);
    wm.global.destroy();
}

fn bind(client: *wl.Client, wm: *WindowManager, version: u32, id: u32) void {
    const wm_v1 = river.WindowManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };

    if (wm.wm_v1 != null) {
        wm_v1.sendUnavailable();
        wm_v1.setHandler(?*anyopaque, handleRequestInert, null, null);
        return;
    }

    wm.wm_v1 = wm_v1;
    wm_v1.setHandler(*WindowManager, handleRequest, null, wm);
}

fn handleRequestInert(
    wm_v1: *river.WindowManagerV1,
    request: river.WindowManagerV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) wm_v1.destroy();
}

fn handleRequest(
    wm_v1: *river.WindowManagerV1,
    request: river.WindowManagerV1.Request,
    wm: *WindowManager,
) void {
    assert(wm.wm_v1 == wm_v1);
    switch (request) {
        .stop => {
            wm.wm_v1 = null;
            wm_v1.sendFinished();
            wm_v1.setHandler(?*anyopaque, handleRequestInert, null, null);
        },
        .destroy => {
            // XXX send protocol error
        },
        .ack_update => |_| {},
        .commit => {},
        .get_seat => |_| {},
        .get_shell_surface => |_| {},
    }
}
