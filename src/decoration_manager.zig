const std = @import("std");
const c = @import("c.zig");

const Decoration = @import("decoration.zig").Decoration;
const Server = @import("server.zig").Server;

pub const DecorationManager = struct {
    const Self = @This();

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
        const decoration_manager = @fieldParentPtr(
            DecorationManager,
            "listen_new_toplevel_decoration",
            listener.?,
        );
        const wlr_xdg_toplevel_decoration = @ptrCast(
            *c.wlr_xdg_toplevel_decoration_v1,
            @alignCast(@alignOf(*c.wlr_xdg_toplevel_decoration_v1), data),
        );

        const node = decoration_manager.decorations.allocateNode(decoration_manager.server.allocator) catch unreachable;
        node.data.init(decoration_manager, wlr_xdg_toplevel_decoration);
        decoration_manager.decorations.prepend(node);
    }
};
