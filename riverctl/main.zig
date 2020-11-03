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

const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zriver = wayland.client.zriver;

const SetupContext = struct {
    river_control: ?*zriver.ControlV1 = null,
    seat: ?*wl.Seat = null,
};

pub fn main() !void {
    const display = try wl.Display.connect(null);
    const registry = try display.getRegistry();

    var context = SetupContext{};

    registry.setListener(*SetupContext, registryListener, &context) catch unreachable;
    _ = try display.roundtrip();

    const river_control = context.river_control orelse return error.RiverControlNotAdvertised;
    const seat = context.seat orelse return error.SeatNotAdverstised;

    // Skip our name, send all other args
    // This next line is needed cause of https://github.com/ziglang/zig/issues/2622
    const args = std.os.argv;
    for (args[1..]) |arg| river_control.addArgument(arg);

    const callback = try river_control.runCommand(seat);

    callback.setListener(?*c_void, callbackListener, null) catch unreachable;

    // Loop until our callback is called and we exit.
    while (true) _ = try display.dispatch();
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *SetupContext) void {
    switch (event) {
        .global => |global| {
            if (context.seat == null and std.cstr.cmp(global.interface, wl.Seat.getInterface().name) == 0) {
                context.seat = registry.bind(global.name, wl.Seat, 1) catch return;
            } else if (std.cstr.cmp(global.interface, zriver.ControlV1.getInterface().name) == 0) {
                context.river_control = registry.bind(global.name, zriver.ControlV1, 1) catch return;
            }
        },
        .global_remove => {},
    }
}

fn callbackListener(callback: *zriver.CommandCallbackV1, event: zriver.CommandCallbackV1.Event, _: ?*c_void) void {
    switch (event) {
        .success => |success| {
            if (std.mem.len(success.output) > 0) {
                const stdout = std.io.getStdOut().outStream();
                stdout.print("{}\n", .{success.output}) catch @panic("failed to write to stdout");
            }
            std.os.exit(0);
        },
        .failure => |failure| {
            std.debug.print("Error: {}\n", .{failure.failure_message});
            std.os.exit(1);
        },
    }
}
