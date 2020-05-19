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

const std = @import("std");

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("river-window-management-unstable-v1-client-protocol.h");
});

const wl_registry_listener = c.wl_registry_listener{
    .global = handleGlobal,
    .global_remove = handleGlobalRemove,
};

var river_window_manager: ?*c.zriver_window_manager_v1 = null;

pub fn main() !void {
    const wl_display = c.wl_display_connect(null) orelse return error.CantConnectToDisplay;
    const wl_registry = c.wl_display_get_registry(wl_display);

    _ = c.wl_registry_add_listener(wl_registry, &wl_registry_listener, null);
    if (c.wl_display_roundtrip(wl_display) == -1) return error.RoundtripFailed;

    const wm = river_window_manager orelse return error.RiverWMNotAdvertised;

    var command: c.wl_array = undefined;
    c.wl_array_init(&command);
    var it = std.process.args();
    // Skip our name
    _ = it.nextPosix();
    while (it.nextPosix()) |arg| {
        // Add one as we need to copy the null terminators as well
        var ptr = @ptrCast([*]u8, c.wl_array_add(&command, arg.len + 1) orelse
            return error.OutOfMemory);
        for (arg) |ch, i| ptr[i] = ch;
        ptr[arg.len] = 0;
    }

    c.zriver_window_manager_v1_run_command(wm, &command);
    if (c.wl_display_roundtrip(wl_display) == -1) return error.RoundtripFailed;
}

fn handleGlobal(
    data: ?*c_void,
    wl_registry: ?*c.wl_registry,
    name: u32,
    interface: ?[*:0]const u8,
    version: u32,
) callconv(.C) void {
    // We only care about the river_window_manager global
    if (std.mem.eql(
        u8,
        std.mem.spanZ(interface.?),
        std.mem.spanZ(@ptrCast([*:0]const u8, c.zriver_window_manager_v1_interface.name.?)),
    )) {
        river_window_manager = @ptrCast(
            *c.zriver_window_manager_v1,
            c.wl_registry_bind(wl_registry, name, &c.zriver_window_manager_v1_interface, 1),
        );
    }
}

/// Ignore the event
fn handleGlobalRemove(data: ?*c_void, wl_registry: ?*c.wl_registry, name: u32) callconv(.C) void {}
