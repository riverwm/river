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
    @cInclude("river-control-unstable-v1-client-protocol.h");
});

const wl_registry_listener = c.wl_registry_listener{
    .global = handleGlobal,
    .global_remove = handleGlobalRemove,
};

const command_callback_listener = c.zriver_command_callback_v1_listener{
    .success = handleSuccess,
    .failure = handleFailure,
};

var river_control_optional: ?*c.zriver_control_v1 = null;

pub fn main() !void {
    const wl_display = c.wl_display_connect(null) orelse return error.CantConnectToDisplay;
    const wl_registry = c.wl_display_get_registry(wl_display);

    if (c.wl_registry_add_listener(wl_registry, &wl_registry_listener, null) < 0)
        return error.FailedToAddListener;
    if (c.wl_display_roundtrip(wl_display) < 0) return error.RoundtripFailed;

    const river_control = river_control_optional orelse return error.RiverControlNotAdvertised;

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

    const command_callback = c.zriver_control_v1_run_command(river_control, &command);
    if (c.zriver_command_callback_v1_add_listener(
        command_callback,
        &command_callback_listener,
        null,
    ) < 0) return error.FailedToAddListener;

    // Loop until our callback is called and we exit.
    while (true) if (c.wl_display_dispatch(wl_display) < 0) return error.DispatchFailed;
}

fn handleGlobal(
    data: ?*c_void,
    wl_registry: ?*c.wl_registry,
    name: u32,
    interface: ?[*:0]const u8,
    version: u32,
) callconv(.C) void {
    // We only care about the river_control global
    if (std.mem.eql(
        u8,
        std.mem.spanZ(interface.?),
        std.mem.spanZ(@ptrCast([*:0]const u8, c.zriver_control_v1_interface.name.?)),
    )) {
        river_control_optional = @ptrCast(
            *c.zriver_control_v1,
            c.wl_registry_bind(wl_registry, name, &c.zriver_control_v1_interface, 1),
        );
    }
}

/// Ignore the event
fn handleGlobalRemove(data: ?*c_void, wl_registry: ?*c.wl_registry, name: u32) callconv(.C) void {}

/// On success we simply exit with a clean exit code
fn handleSuccess(data: ?*c_void, callback: ?*c.zriver_command_callback_v1) callconv(.C) void {
    std.os.exit(0);
}

/// Print the failure message and exit non-zero
fn handleFailure(
    data: ?*c_void,
    callback: ?*c.zriver_command_callback_v1,
    failure_message: ?[*:0]const u8,
) callconv(.C) void {
    if (failure_message) |message| {
        std.debug.warn("Error: {}\n", .{failure_message});
    }
    std.os.exit(1);
}
