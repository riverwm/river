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
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Server = @import("Server.zig");
const View = @import("View.zig");

xdg_toplevel_decoration: *wlr.XdgToplevelDecorationV1,

destroy: wl.Listener(*wlr.XdgToplevelDecorationV1) =
    wl.Listener(*wlr.XdgToplevelDecorationV1).init(handleDestroy),
request_mode: wl.Listener(*wlr.XdgToplevelDecorationV1) =
    wl.Listener(*wlr.XdgToplevelDecorationV1).init(handleRequestMode),

pub fn init(self: *Self, xdg_toplevel_decoration: *wlr.XdgToplevelDecorationV1) void {
    self.* = .{ .xdg_toplevel_decoration = xdg_toplevel_decoration };

    xdg_toplevel_decoration.events.destroy.add(&self.destroy);
    xdg_toplevel_decoration.events.request_mode.add(&self.request_mode);

    handleRequestMode(&self.request_mode, self.xdg_toplevel_decoration);
}

fn handleDestroy(
    listener: *wl.Listener(*wlr.XdgToplevelDecorationV1),
    _: *wlr.XdgToplevelDecorationV1,
) void {
    const self = @fieldParentPtr(Self, "destroy", listener);
    self.destroy.link.remove();
    self.request_mode.link.remove();

    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    server.decoration_manager.decorations.remove(node);
    util.gpa.destroy(node);
}

fn handleRequestMode(
    listener: *wl.Listener(*wlr.XdgToplevelDecorationV1),
    _: *wlr.XdgToplevelDecorationV1,
) void {
    const self = @fieldParentPtr(Self, "request_mode", listener);

    const view = @intToPtr(*View, self.xdg_toplevel_decoration.surface.data);
    if (server.config.csdAllowed(view)) {
        _ = self.xdg_toplevel_decoration.setMode(.client_side);
    } else {
        _ = self.xdg_toplevel_decoration.setMode(.server_side);
    }
}
