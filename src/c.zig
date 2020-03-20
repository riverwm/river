// Functions that couldn't be automatically translated

pub const c = @cImport({
    @cDefine("WLR_USE_UNSTABLE", {});
    @cInclude("time.h");
    @cInclude("stdlib.h");
    @cInclude("wayland-server-core.h");
    @cInclude("wlr/backend.h");
    @cInclude("wlr/render/wlr_renderer.h");
    @cInclude("wlr/types/wlr_cursor.h");
    @cInclude("wlr/types/wlr_compositor.h");
    @cInclude("wlr/types/wlr_data_device.h");
    @cInclude("wlr/types/wlr_input_device.h");
    @cInclude("wlr/types/wlr_keyboard.h");
    @cInclude("wlr/types/wlr_matrix.h");
    @cInclude("wlr/types/wlr_output.h");
    @cInclude("wlr/types/wlr_output_layout.h");
    @cInclude("wlr/types/wlr_pointer.h");
    @cInclude("wlr/types/wlr_seat.h");
    @cInclude("wlr/types/wlr_xcursor_manager.h");
    @cInclude("wlr/types/wlr_xdg_shell.h");
    @cInclude("wlr/util/log.h");
    @cInclude("xkbcommon/xkbcommon.h");
});

pub const manual = struct {
    pub inline fn xkb_map_new_from_names(context: var, names: var, flags: var) ?*c.struct_xkb_keymap {
        return c.xkb_keymap_new_from_names(context, names, flags);
    }
};
