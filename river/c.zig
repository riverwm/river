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

pub usingnamespace @cImport({
    @cDefine("_POSIX_C_SOURCE", "200809L");
    @cDefine("WLR_USE_UNSTABLE", {});

    @cInclude("stdlib.h");
    @cInclude("time.h");
    @cInclude("unistd.h");

    @cInclude("linux/input-event-codes.h");
    @cInclude("libevdev/libevdev.h");

    @cInclude("wayland-server-core.h");
    @cInclude("wlr/backend.h");
    @cInclude("wlr/backend/multi.h");
    @cInclude("wlr/backend/noop.h");
    //@cInclude("wlr/render/wlr_renderer.h");
    @cInclude("wlr/types/wlr_buffer.h");
    @cInclude("wlr/types/wlr_compositor.h");
    @cInclude("wlr/types/wlr_cursor.h");
    @cInclude("wlr/types/wlr_data_control_v1.h");
    @cInclude("wlr/types/wlr_data_device.h");
    @cInclude("wlr/types/wlr_export_dmabuf_v1.h");
    @cInclude("wlr/types/wlr_gamma_control_v1.h");
    @cInclude("wlr/types/wlr_idle.h");
    @cInclude("wlr/types/wlr_input_device.h");
    @cInclude("wlr/types/wlr_input_inhibitor.h");
    @cInclude("wlr/types/wlr_keyboard.h");
    @cInclude("wlr/types/wlr_layer_shell_v1.h");
    @cInclude("wlr/types/wlr_matrix.h");
    @cInclude("wlr/types/wlr_output.h");
    @cInclude("wlr/types/wlr_output_layout.h");
    @cInclude("wlr/types/wlr_output_management_v1.h");
    @cInclude("wlr/types/wlr_output_power_management_v1.h");
    @cInclude("wlr/types/wlr_pointer.h");
    @cInclude("wlr/types/wlr_primary_selection.h");
    @cInclude("wlr/types/wlr_primary_selection_v1.h");
    @cInclude("wlr/types/wlr_screencopy_v1.h");
    @cInclude("wlr/types/wlr_seat.h");
    @cInclude("wlr/types/wlr_viewporter.h");
    @cInclude("wlr/types/wlr_virtual_pointer_v1.h");
    @cInclude("wlr/types/wlr_virtual_keyboard_v1.h");
    @cInclude("wlr/types/wlr_xcursor_manager.h");
    @cInclude("wlr/types/wlr_xdg_decoration_v1.h");
    @cInclude("wlr/types/wlr_xdg_output_v1.h");
    @cInclude("wlr/types/wlr_xdg_shell.h");
    if (@import("build_options").xwayland) @cInclude("wlr/xwayland.h");
    @cInclude("wlr/util/log.h");
    @cInclude("xkbcommon/xkbcommon.h");

    // Contains a subset of functions from wlr/backend.h and wlr/render/wlr_renderer.h
    // that can be automatically imported
    @cInclude("include/bindings.h");

    @cInclude("river-control-unstable-v1-protocol.h");
    @cInclude("river-status-unstable-v1-protocol.h");
});

// These are needed because zig currently names translated anonymous unions
// with a global counter, which makes code unportable.
// See https://github.com/ifreund/river/issues/17
pub const wlr_xdg_surface_union = @typeInfo(wlr_xdg_surface).Struct.fields[5].name;
pub const wlr_input_device_union = @typeInfo(wlr_input_device).Struct.fields[8].name;
