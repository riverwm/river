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
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const util = @import("util.zig");

const Server = @import("Server.zig");

server: *Server,

xdg_toplevel_decoration: *wlr.XdgToplevelDecorationV1,

// zig fmt: off
destroy: wl.Listener(*wlr.XdgToplevelDecorationV1) =
    wl.Listener(*wlr.XdgToplevelDecorationV1).init(handleDestroy),
request_mode: wl.Listener(*wlr.XdgToplevelDecorationV1) =
    wl.Listener(*wlr.XdgToplevelDecorationV1).init(handleRequestMode),
// zig fmt: on

pub fn init(
    self: *Self,
    server: *Server,
    xdg_toplevel_decoration: *wlr.XdgToplevelDecorationV1,
) void {
    self.* = .{ .server = server, .xdg_toplevel_decoration = xdg_toplevel_decoration };

    xdg_toplevel_decoration.events.destroy.add(&self.destroy);
    xdg_toplevel_decoration.events.request_mode.add(&self.request_mode);

    handleRequestMode(&self.request_mode, self.xdg_toplevel_decoration);
}

fn handleDestroy(
    listener: *wl.Listener(*wlr.XdgToplevelDecorationV1),
    xdg_toplevel_decoration: *wlr.XdgToplevelDecorationV1,
) void {
    const self = @fieldParentPtr(Self, "destroy", listener);
    util.gpa.destroy(self);
}

fn handleRequestMode(
    listener: *wl.Listener(*wlr.XdgToplevelDecorationV1),
    xdg_toplevel_decoration: *wlr.XdgToplevelDecorationV1,
) void {
    const self = @fieldParentPtr(Self, "request_mode", listener);

    const toplevel = self.xdg_toplevel_decoration.surface.role_data.toplevel;
    const app_id: [*:0]const u8 = if (toplevel.app_id) |id| id else "NULL";

    _ = self.xdg_toplevel_decoration.setMode(
        for (self.server.config.csd_filter.items) |filter_app_id| {
            if (std.mem.eql(u8, std.mem.span(app_id), filter_app_id)) break .client_side;
        } else .server_side,
    );
}
