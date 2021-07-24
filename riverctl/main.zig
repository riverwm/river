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
const io = std.io;
const os = std.os;
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zriver = wayland.client.zriver;

const flags = @import("flags");

const usage =
    \\usage: riverctl [options] <command>
    \\
    \\  -help           Print this help message and exit.
    \\  -version        Print the version number and exit.
    \\
    \\Complete documentation of the recognized commands may be found in
    \\the riverctl(1) man page.
    \\
;

const gpa = std.heap.c_allocator;

pub const Globals = struct {
    control: ?*zriver.ControlV1 = null,
    seat: ?*wl.Seat = null,
};

pub fn main() !void {
    _main() catch |err| {
        if (std.builtin.mode == .Debug)
            return err;

        switch (err) {
            error.RiverControlNotAdvertised => fatal(
                \\The Wayland server does not support river-control-unstable-v1.
                \\Do your versions of river and riverctl match?
            , .{}),
            error.SeatNotAdverstised => fatal(
                \\The Wayland server did not advertise any seat.
            , .{}),
            else => return err,
        }
    };
}

fn _main() !void {
    // This line is here because of https://github.com/ziglang/zig/issues/7807
    const argv: [][*:0]const u8 = os.argv;
    const result = flags.parse(argv[1..], &[_]flags.Flag{
        .{ .name = "-help", .kind = .boolean },
        .{ .name = "-version", .kind = .boolean },
    }) catch {
        try io.getStdErr().writeAll(usage);
        os.exit(1);
    };
    if (result.boolFlag("-help")) {
        try io.getStdOut().writeAll(usage);
        os.exit(0);
    }
    if (result.boolFlag("-version")) {
        try io.getStdOut().writeAll(@import("build_options").version);
        os.exit(0);
    }

    const display = try wl.Display.connect(null);
    const registry = try display.getRegistry();

    var globals = Globals{};

    registry.setListener(*Globals, registryListener, &globals);
    _ = try display.roundtrip();

    const control = globals.control orelse return error.RiverControlNotAdvertised;
    const seat = globals.seat orelse return error.SeatNotAdverstised;

    for (result.args) |arg| control.addArgument(arg);

    const callback = try control.runCommand(seat);
    callback.setListener(?*c_void, callbackListener, null);

    // Loop until our callback is called and we exit.
    while (true) _ = try display.dispatch();
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |global| {
            if (std.cstr.cmp(global.interface, wl.Seat.getInterface().name) == 0) {
                assert(globals.seat == null); // TODO: support multiple seats
                globals.seat = registry.bind(global.name, wl.Seat, 1) catch @panic("out of memory");
            } else if (std.cstr.cmp(global.interface, zriver.ControlV1.getInterface().name) == 0) {
                globals.control = registry.bind(global.name, zriver.ControlV1, 1) catch @panic("out of memory");
            }
        },
        .global_remove => {},
    }
}

fn callbackListener(callback: *zriver.CommandCallbackV1, event: zriver.CommandCallbackV1.Event, _: ?*c_void) void {
    switch (event) {
        .success => |success| {
            if (mem.len(success.output) > 0) {
                const stdout = std.io.getStdOut().writer();
                stdout.print("{s}\n", .{success.output}) catch @panic("failed to write to stdout");
            }
            os.exit(0);
        },
        .failure => |failure| {
            // A small hack to provide usage text when river reports an unknown command.
            if (std.cstr.cmp(failure.failure_message, "unknown command") == 0) {
                std.log.err("unknown command", .{});
                io.getStdErr().writeAll(usage) catch {};
                os.exit(1);
            }
            fatal("{s}", .{failure.failure_message});
        },
    }
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.os.exit(1);
}
