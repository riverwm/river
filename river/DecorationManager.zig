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

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Decoration = @import("Decoration.zig");
const Server = @import("Server.zig");

xdg_decoration_manager: *wlr.XdgDecorationManagerV1,

// zig fmt: off
new_toplevel_decoration: wl.Listener(*wlr.XdgToplevelDecorationV1) =
    wl.Listener(*wlr.XdgToplevelDecorationV1).init(handleNewToplevelDecoration),
// zig fmt: on

pub fn init(self: *Self) !void {
    self.* = .{
        .xdg_decoration_manager = try wlr.XdgDecorationManagerV1.create(server.wl_server),
    };

    self.xdg_decoration_manager.events.new_toplevel_decoration.add(&self.new_toplevel_decoration);
}

fn handleNewToplevelDecoration(
    listener: *wl.Listener(*wlr.XdgToplevelDecorationV1),
    xdg_toplevel_decoration: *wlr.XdgToplevelDecorationV1,
) void {
    const self = @fieldParentPtr(Self, "new_toplevel_decoration", listener);
    const decoration = util.gpa.create(Decoration) catch {
        xdg_toplevel_decoration.resource.postNoMemory();
        return;
    };
    decoration.init(xdg_toplevel_decoration);
}
