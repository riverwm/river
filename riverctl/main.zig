// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020-2021 The River Developers
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
const mem = std.mem;
const os = std.os;
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;
const zriver = wayland.client.zriver;
const zxdg = wayland.client.zxdg;

const gpa = std.heap.c_allocator;

const options = @import("options.zig");

pub const Output = struct {
    wl_output: *wl.Output,
    name: []const u8,
};

pub const Globals = struct {
    control: ?*zriver.ControlV1 = null,
    options_manager: ?*river.OptionsManagerV2 = null,
    status_manager: ?*zriver.StatusManagerV1 = null,
    seat: ?*wl.Seat = null,
    output_manager: ?*zxdg.OutputManagerV1 = null,
    outputs: std.ArrayList(Output) = std.ArrayList(Output).init(gpa),
};

pub fn main() !void {
    _main() catch |err| {
        if (std.builtin.mode == .Debug)
            return err;

        switch (err) {
            error.RiverControlNotAdvertised => printErrorExit(
                \\The Wayland server does not support river-control-unstable-v1.
                \\Do your versions of river and riverctl match?
            , .{}),
            error.RiverStatusManagerNotAdvertised => printErrorExit(
                \\The Wayland server does not support river-status-unstable-v1.
                \\Do your versions of river and riverctl match?
            , .{}),
            error.RiverOptionsManagerNotAdvertised => printErrorExit(
                \\The Wayland server does not support river-options-unstable-v1.
                \\Do your versions of river and riverctl match?
            , .{}),
            error.SeatNotAdverstised => printErrorExit(
                \\The Wayland server did not advertise any seat.
            , .{}),
            error.XdgOutputNotAdvertised => printErrorExit(
                \\The Wayland server does not support xdg-output-unstable-v1.
            , .{}),
            else => return err,
        }
    };
}

fn _main() !void {
    const display = try wl.Display.connect(null);
    const registry = try display.getRegistry();

    var globals = Globals{};

    registry.setListener(*Globals, registryListener, &globals) catch unreachable;
    _ = try display.roundtrip();

    if (os.argv.len > 2 and mem.eql(u8, "declare-option", mem.span(os.argv[1]))) {
        try options.declareOption(display, &globals);
    } else if (os.argv.len > 2 and mem.eql(u8, "get-option", mem.span(os.argv[1]))) {
        try options.getOption(display, &globals);
    } else if (os.argv.len > 2 and mem.eql(u8, "set-option", mem.span(os.argv[1]))) {
        try options.setOption(display, &globals);
    } else if (os.argv.len > 2 and mem.eql(u8, "unset-option", mem.span(os.argv[1]))) {
        try options.unsetOption(display, &globals);
    } else if (os.argv.len > 2 and mem.eql(u8, "mod-option", mem.span(os.argv[1]))) {
        try options.modOption(display, &globals);
    } else {
        const control = globals.control orelse return error.RiverControlNotAdvertised;
        const seat = globals.seat orelse return error.SeatNotAdverstised;

        // Skip our name, send all other args
        // This next line is needed cause of https://github.com/ziglang/zig/issues/2622
        const args = os.argv;
        for (args[1..]) |arg| control.addArgument(arg);

        const callback = try control.runCommand(seat);

        callback.setListener(?*c_void, callbackListener, null) catch unreachable;

        // Loop until our callback is called and we exit.
        while (true) _ = try display.dispatch();
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |global| {
            if (std.cstr.cmp(global.interface, wl.Seat.getInterface().name) == 0) {
                assert(globals.seat == null); // TODO: support multiple seats
                globals.seat = registry.bind(global.name, wl.Seat, 1) catch @panic("out of memory");
            } else if (std.cstr.cmp(global.interface, zriver.ControlV1.getInterface().name) == 0) {
                globals.control = registry.bind(global.name, zriver.ControlV1, 1) catch @panic("out of memory");
            } else if (std.cstr.cmp(global.interface, river.OptionsManagerV2.getInterface().name) == 0) {
                globals.options_manager = registry.bind(global.name, river.OptionsManagerV2, 1) catch @panic("out of memory");
            } else if (std.cstr.cmp(global.interface, zriver.StatusManagerV1.getInterface().name) == 0) {
                globals.status_manager = registry.bind(global.name, zriver.StatusManagerV1, 1) catch @panic("out of memory");
            } else if (std.cstr.cmp(global.interface, zxdg.OutputManagerV1.getInterface().name) == 0 and global.version >= 2) {
                globals.output_manager = registry.bind(global.name, zxdg.OutputManagerV1, 2) catch @panic("out of memory");
            } else if (std.cstr.cmp(global.interface, wl.Output.getInterface().name) == 0) {
                const output = registry.bind(global.name, wl.Output, 1) catch @panic("out of memory");
                globals.outputs.append(.{ .wl_output = output, .name = undefined }) catch @panic("out of memory");
            }
        },
        .global_remove => {},
    }
}

fn callbackListener(callback: *zriver.CommandCallbackV1, event: zriver.CommandCallbackV1.Event, _: ?*c_void) void {
    switch (event) {
        .success => |success| {
            if (mem.len(success.output) > 0) {
                const stdout = std.io.getStdOut().outStream();
                stdout.print("{}\n", .{success.output}) catch @panic("failed to write to stdout");
            }
            os.exit(0);
        },
        .failure => |failure| {
            std.debug.print("Error: {}\n", .{failure.failure_message});
            os.exit(1);
        },
    }
}

pub fn printErrorExit(comptime format: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr().outStream();
    stderr.print("err: " ++ format ++ "\n", args) catch std.os.exit(1);
    std.os.exit(1);
}
