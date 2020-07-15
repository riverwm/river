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
const util = @import("util.zig");

const Decoration = @import("Decoration.zig");
const Server = @import("Server.zig");

server: *Server,

wlr_xdg_decoration_manager: *c.wlr_xdg_decoration_manager_v1,

decorations: std.SinglyLinkedList(Decoration),

listen_new_toplevel_decoration: c.wl_listener,

pub fn init(self: *Self, server: *Server) !void {
    self.wlr_xdg_decoration_manager = c.wlr_xdg_decoration_manager_v1_create(server.wl_display) orelse
        return error.OutOfMemory;

    self.server = server;

    self.listen_new_toplevel_decoration.notify = handleNewToplevelDecoration;
    c.wl_signal_add(
        &self.wlr_xdg_decoration_manager.events.new_toplevel_decoration,
        &self.listen_new_toplevel_decoration,
    );
}

fn handleNewToplevelDecoration(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_new_toplevel_decoration", listener.?);
    const wlr_xdg_toplevel_decoration = util.voidCast(c.wlr_xdg_toplevel_decoration_v1, data.?);

    const decoration = util.gpa.create(Decoration) catch {
        c.wl_resource_post_no_memory(wlr_xdg_toplevel_decoration.resource);
        return;
    };
    decoration.init(self.server, wlr_xdg_toplevel_decoration);
}
