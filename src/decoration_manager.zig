const Self = @This();

const std = @import("std");

const c = @import("c.zig");

const Decoration = @import("decoration.zig");
const Server = @import("server.zig");

server: *Server,

wlr_xdg_decoration_manager: *c.wlr_xdg_decoration_manager_v1,

decorations: std.SinglyLinkedList(Decoration),

listen_new_toplevel_decoration: c.wl_listener,

pub fn init(self: *Self, server: *Server) !void {
    self.server = server;
    self.wlr_xdg_decoration_manager = c.wlr_xdg_decoration_manager_v1_create(server.wl_display) orelse
        return error.CantCreateWlrXdgDecorationManager;

    self.listen_new_toplevel_decoration.notify = handleNewToplevelDecoration;
    c.wl_signal_add(
        &self.wlr_xdg_decoration_manager.events.new_toplevel_decoration,
        &self.listen_new_toplevel_decoration,
    );
}

fn handleNewToplevelDecoration(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_new_toplevel_decoration", listener.?);
    const wlr_xdg_toplevel_decoration = @ptrCast(
        *c.wlr_xdg_toplevel_decoration_v1,
        @alignCast(@alignOf(*c.wlr_xdg_toplevel_decoration_v1), data),
    );

    const node = self.decorations.allocateNode(self.server.allocator) catch unreachable;
    node.data.init(self, wlr_xdg_toplevel_decoration);
    self.decorations.prepend(node);
}
