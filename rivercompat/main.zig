// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2024 The River Developers
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
const fmt = std.fmt;
const mem = std.mem;
const math = std.math;
const posix = std.posix;
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const river = wayland.client.river;
const flags = @import("flags");

const WindowManager = @import("WindowManager.zig");

const gpa = std.heap.c_allocator;

const usage =
    \\usage: rivercompat [options]
    \\
    \\  -h              Print this help message and exit.
    \\  -version        Print the version number and exit.
    \\
;

const Globals = struct {
    wm_v1: ?*river.WindowManagerV1 = null,
    compositor: ?*wl.Compositor = null,
    viewporter: ?*wp.Viewporter = null,
    single_pixel: ?*wp.SinglePixelBufferManagerV1 = null,

    fn handleEvent(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
        switch (event) {
            .global => |global| {
                if (mem.orderZ(u8, global.interface, river.WindowManagerV1.interface.name) == .eq) {
                    globals.wm_v1 = registry.bind(global.name, river.WindowManagerV1, 1) catch return;
                } else if (mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                    globals.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
                } else if (mem.orderZ(u8, global.interface, wp.Viewporter.interface.name) == .eq) {
                    globals.viewporter = registry.bind(global.name, wp.Viewporter, 1) catch return;
                } else if (mem.orderZ(u8, global.interface, wp.SinglePixelBufferManagerV1.interface.name) == .eq) {
                    globals.single_pixel = registry.bind(global.name, wp.SinglePixelBufferManagerV1, 1) catch return;
                }
            },
            .global_remove => {},
        }
    }
};

const Output = struct {
    output_v1: *river.OutputV1,
};

pub fn main() !void {
    const result = flags.parser([*:0]const u8, &[_]flags.Flag{
        .{ .name = "h", .kind = .boolean },
        .{ .name = "version", .kind = .boolean },
    }).parse(std.os.argv[1..]) catch {
        try std.io.getStdErr().writeAll(usage);
        posix.exit(1);
    };
    if (result.flags.h) {
        try std.io.getStdOut().writeAll(usage);
        posix.exit(0);
    }
    if (result.args.len != 0) fatalPrintUsage("unknown option '{s}'", .{result.args[0]});

    if (result.flags.version) {
        try std.io.getStdOut().writeAll(@import("build_options").version ++ "\n");
        posix.exit(0);
    }

    const display = wl.Display.connect(null) catch {
        std.debug.print("Unable to connect to Wayland server.\n", .{});
        posix.exit(1);
    };
    defer display.disconnect();

    var globals: Globals = .{};
    const registry = try display.getRegistry();
    registry.setListener(*Globals, Globals.handleEvent, &globals);
    if (display.roundtrip() != .SUCCESS) fatal("initial roundtrip failed", .{});

    const wm_v1 = globals.wm_v1 orelse
        fatal("wayland compositor does not support river-window-management-v1", .{});
    const compositor = globals.compositor orelse
        fatal("wayland compositor does not support wl_compositor", .{});
    const viewporter = globals.viewporter orelse
        fatal("wayland compositor does not support viewporter", .{});
    const single_pixel = globals.single_pixel orelse
        fatal("wayland compositor does not support wp-single-pixel-buffer-v1", .{});

    var wm: WindowManager = undefined;
    wm.init(wm_v1, compositor, viewporter, single_pixel);

    while (true) {
        if (display.dispatch() != .SUCCESS) fatal("failed to dispatch wayland events", .{});
    }
}

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    posix.exit(1);
}

fn fatalPrintUsage(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.io.getStdErr().writeAll(usage) catch {};
    posix.exit(1);
}
