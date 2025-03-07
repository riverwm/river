// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020-2021 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
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
const posix = std.posix;
const assert = std.debug.assert;
const builtin = @import("builtin");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zriver = wayland.client.zriver;

const flags = @import("flags");

const usage =
    \\usage: riverctl [options] <command>
    \\
    \\  -h              Print this help message and exit.
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
        switch (err) {
            error.RiverControlNotAdvertised => fatal(
                \\The Wayland server does not support river-control-unstable-v1.
                \\Do your versions of river and riverctl match?
            , .{}),
            error.SeatNotAdverstised => fatal(
                \\The Wayland server did not advertise any seat.
            , .{}),
            error.ConnectFailed => {
                std.log.err("Unable to connect to the Wayland server.", .{});
                if (posix.getenvZ("WAYLAND_DISPLAY") == null) {
                    fatal("WAYLAND_DISPLAY is not set.", .{});
                } else {
                    fatal("Does WAYLAND_DISPLAY contain the socket name of a running server?", .{});
                }
            },
            else => return err,
        }
    };
}

fn _main() !void {
    const result = flags.parser([*:0]const u8, &.{
        .{ .name = "h", .kind = .boolean },
        .{ .name = "version", .kind = .boolean },
    }).parse(std.os.argv[1..]) catch {
        try io.getStdErr().writeAll(usage);
        posix.exit(1);
    };
    if (result.flags.h) {
        try io.getStdOut().writeAll(usage);
        posix.exit(0);
    }
    if (result.flags.version) {
        try io.getStdOut().writeAll(@import("build_options").version ++ "\n");
        posix.exit(0);
    }

    const display = try wl.Display.connect(null);
    const registry = try display.getRegistry();

    var globals = Globals{};

    registry.setListener(*Globals, registryListener, &globals);
    if (display.roundtrip() != .SUCCESS) fatal("initial roundtrip failed", .{});

    const control = globals.control orelse return error.RiverControlNotAdvertised;
    const seat = globals.seat orelse return error.SeatNotAdverstised;

    for (result.args) |arg| control.addArgument(arg);

    const callback = try control.runCommand(seat);
    callback.setListener(?*anyopaque, callbackListener, null);

    // Loop until our callback is called and we exit.
    while (true) {
        if (display.dispatch() != .SUCCESS) fatal("failed to dispatch wayland events", .{});
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |global| {
            if (mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                assert(globals.seat == null); // TODO: support multiple seats
                globals.seat = registry.bind(global.name, wl.Seat, 1) catch @panic("out of memory");
            } else if (mem.orderZ(u8, global.interface, zriver.ControlV1.interface.name) == .eq) {
                globals.control = registry.bind(global.name, zriver.ControlV1, 1) catch @panic("out of memory");
            }
        },
        .global_remove => {},
    }
}

fn callbackListener(_: *zriver.CommandCallbackV1, event: zriver.CommandCallbackV1.Event, _: ?*anyopaque) void {
    switch (event) {
        .success => |success| {
            if (mem.len(success.output) > 0) {
                const stdout = io.getStdOut().writer();
                stdout.print("{s}\n", .{success.output}) catch @panic("failed to write to stdout");
            }
            posix.exit(0);
        },
        .failure => |failure| {
            // A small hack to provide usage text when river reports an unknown command.
            if (mem.orderZ(u8, failure.failure_message, "unknown command") == .eq) {
                std.log.err("unknown command", .{});
                io.getStdErr().writeAll(usage) catch {};
                posix.exit(1);
            }
            fatal("{s}", .{failure.failure_message});
        },
    }
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    posix.exit(1);
}
