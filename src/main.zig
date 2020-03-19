const c = @cImport({
    @cDefine("WLR_USE_UNSTABLE", {});
    @cInclude("wayland-server-core.h");
    @cInclude("wlr/backend.h");
    @cInclude("wlr/util/log.h");
    @cInclude("wlr/types/wlr_xdg_shell.h>");
});
const std = @import("std");

const CursorMode = enum {
    Passthrough,
    Move,
    Resize,
};

fn create_list() c.wl_list {
    return c.wl_list{
        .prev = null,
        .next = null,
    };
}

fn create_listener() c.wl_listener {
    return c.wl_listener{
        .link = create_list(),
        .notify = null,
    };
}

const Server = struct {
    wl_display: ?*c.wl_display,
    backend: ?*c.wlr_backend,
    renderer: ?*c.wlr_renderer,

    xdg_shell: ?*c.wlr_xdg_shell,
    new_xdg_surface: c.wl_listener,
    views: c.wl_list,

    cursor: ?*c.wlr_cursor,
    cursor_mgr: ?*c.wlr_xcursor_manager,
    cursor_motion: c.wl_listener,
    cursor_motion_absolute: c.wl_listener,
    cursor_button: c.wl_listener,
    cursor_axis: c.wl_listener,
    cursor_frame: c.wl_listener,

    seat: ?*c.wlr_seat,
    new_input: c.wl_listener,
    request_cursor: c.wl_listener,
    keyboards: c.wl_list,
    cursor_mode: CursorMode,
    grabbed_view: ?*c.tinywl_view,
    grab_x: f64,
    grab_y: f64,
    grab_width: c_int,
    grab_height: c_int,
    resize_edges: u32,

    output_layout: ?*c.wlr_output_layout,
    outputs: c.wl_list,
    new_output: c.wl_listener,
};

pub fn main() !void {
    std.debug.warn("Starting up.\n", .{});

    c.wlr_log_init(c.enum_wlr_log_importance.WLR_DEBUG, null);

    var server = Server{
        .wl_display = null,
        .backend = null,
        .renderer = null,

        .xdg_shell = null,
        .new_xdg_surface = create_listener(),
        .views = c.wl_list,

        .cursor = null,
        .cursor_mgr = null,
        .cursor_motion = create_listener(),
        .cursor_motion_absolute = create_listener(),
        .cursor_button = create_listener(),
        .cursor_axis = create_listener(),
        .cursor_frame = create_listener(),

        .seat = null,
        .new_input = create_listener(),
        .request_cursor = create_listener(),
        .keyboards = c.wl_list,
        .cursor_mode = CursorMode.Passthrough,
        .grabbed_view = null,
        .grab_x = 0.0,
        .grab_y = 0.0,
        .grab_width = 0,
        .grab_height = 0,
        .resize_edges = 0,

        .output_layout = null,
        .outputs = c.wl_list{ .prev = null, .next = null },
        .new_output = create_listener(){},
    };
}
