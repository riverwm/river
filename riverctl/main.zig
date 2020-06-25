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
var wl_seat_optional: ?*c.wl_seat = null;

pub fn main() !void {
    const wl_display = c.wl_display_connect(null) orelse return error.ConnectError;
    const wl_registry = c.wl_display_get_registry(wl_display);

    if (c.wl_registry_add_listener(wl_registry, &wl_registry_listener, null) < 0) unreachable;
    if (c.wl_display_roundtrip(wl_display) < 0) return error.RoundtripFailed;

    const river_control = river_control_optional orelse return error.RiverControlNotAdvertised;
    const wl_seat = wl_seat_optional orelse return error.SeatNotAdverstised;

    // Skip our name, send all other args
    // This next line is needed cause of https://github.com/ziglang/zig/issues/2622
    const args = std.os.argv;
    for (args[1..]) |arg| c.zriver_control_v1_add_argument(river_control, arg);

    const command_callback = c.zriver_control_v1_run_command(river_control, wl_seat);
    if (c.zriver_command_callback_v1_add_listener(
        command_callback,
        &command_callback_listener,
        null,
    ) < 0) unreachable;

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
    if (std.cstr.cmp(interface.?, @ptrCast([*:0]const u8, c.zriver_control_v1_interface.name.?)) == 0) {
        river_control_optional = @ptrCast(
            *c.zriver_control_v1,
            c.wl_registry_bind(wl_registry, name, &c.zriver_control_v1_interface, 1),
        );
    } else if (std.cstr.cmp(interface.?, @ptrCast([*:0]const u8, c.wl_seat_interface.name.?)) == 0) {
        // river does not yet support multi-seat, so just use the first
        // (and only) seat advertised
        wl_seat_optional = @ptrCast(
            *c.wl_seat,
            c.wl_registry_bind(wl_registry, name, &c.wl_seat_interface, 1),
        );
    }
}

/// Ignore the event
fn handleGlobalRemove(data: ?*c_void, wl_registry: ?*c.wl_registry, name: u32) callconv(.C) void {}

/// Print the output of the command if any and exit
fn handleSuccess(
    data: ?*c_void,
    callback: ?*c.zriver_command_callback_v1,
    output: ?[*:0]const u8,
) callconv(.C) void {
    if (std.mem.len(output.?) > 0) {
        const stdout = std.io.getStdOut().outStream();
        stdout.print("{}\n", .{output}) catch @panic("failed to write to stdout");
    }
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
