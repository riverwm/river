pub usingnamespace @cImport({
    @cDefine("WLR_USE_UNSTABLE", {});
    @cInclude("time.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("wayland-server-core.h");
    //@cInclude("wlr/backend.h");
    //@cInclude("wlr/render/wlr_renderer.h");
    @cInclude("wlr/types/wlr_buffer.h");
    @cInclude("wlr/types/wlr_compositor.h");
    @cInclude("wlr/types/wlr_cursor.h");
    @cInclude("wlr/types/wlr_data_device.h");
    @cInclude("wlr/types/wlr_input_device.h");
    @cInclude("wlr/types/wlr_keyboard.h");
    @cInclude("wlr/types/wlr_matrix.h");
    @cInclude("wlr/types/wlr_output.h");
    @cInclude("wlr/types/wlr_output_layout.h");
    @cInclude("wlr/types/wlr_pointer.h");
    @cInclude("wlr/types/wlr_seat.h");
    @cInclude("wlr/types/wlr_xcursor_manager.h");
    @cInclude("wlr/types/wlr_xdg_decoration_v1.h");
    @cInclude("wlr/types/wlr_xdg_shell.h");
    @cInclude("wlr/util/log.h");
    @cInclude("xkbcommon/xkbcommon.h");

    // Contains a subset of functions from wlr/backend.h and wlr/render/wlr_renderer.h
    // that can be automatically imported
    @cInclude("include/render.h");
});
