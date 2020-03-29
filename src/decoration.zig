const std = @import("std");
const c = @import("c.zig");

const DecorationManager = @import("decoration_manager.zig").DecorationManager;

// TODO: this needs to listen for destroy and free nodes from the deco list
pub const Decoration = struct {
    const Self = @This();

    decoration_manager: *DecorationManager,
    wlr_xdg_toplevel_decoration: *c.wlr_xdg_toplevel_decoration_v1,

    listen_request_mode: c.wl_listener,

    pub fn init(
        self: *Self,
        decoration_manager: *DecorationManager,
        wlr_xdg_toplevel_decoration: *c.wlr_xdg_toplevel_decoration_v1,
    ) void {
        self.decoration_manager = decoration_manager;
        self.wlr_xdg_toplevel_decoration = wlr_xdg_toplevel_decoration;

        self.listen_request_mode.notify = handleRequestMode;
        c.wl_signal_add(&self.wlr_xdg_toplevel_decoration.events.request_mode, &self.listen_request_mode);

        handleRequestMode(&self.listen_request_mode, self.wlr_xdg_toplevel_decoration);
    }

    fn handleRequestMode(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const decoration = @fieldParentPtr(Decoration, "listen_request_mode", listener.?);
        // TODO: we might need to take this configure serial and do a transaction
        _ = c.wlr_xdg_toplevel_decoration_v1_set_mode(
            decoration.wlr_xdg_toplevel_decoration,
            c.wlr_xdg_toplevel_decoration_v1_mode.WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE,
        );
    }
};
