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

// This is an implementation of the  default "tiled" layout of dwm and the
// 3 other orientations thereof. This code is written for the main stack
// to the left and then the input/output values are adjusted to apply
// the necessary transformations to derive the other orientations.
//
// With 4 views and one main on the left, the layout looks something like this:
//
// +-----------------------+------------+
// |                       |            |
// |                       |            |
// |                       |            |
// |                       +------------+
// |                       |            |
// |                       |            |
// |                       |            |
// |                       +------------+
// |                       |            |
// |                       |            |
// |                       |            |
// +-----------------------+------------+

const std = @import("std");
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Args = @import("args.zig").Args;
const FlagDef = @import("args.zig").FlagDef;

const Location = enum {
    top,
    right,
    bottom,
    left,
};

// Configured through command line options
var view_padding: u32 = 6;
var outer_padding: u32 = 6;
var default_main_location: Location = .left;
var default_main_count: u32 = 1;
var default_main_factor: f64 = 0.6;

/// We don't free resources on exit, only when output globals are removed.
const gpa = std.heap.c_allocator;

const Context = struct {
    initialized: bool = false,
    layout_manager: ?*river.LayoutManagerV2 = null,
    outputs: std.TailQueue(Output) = .{},

    fn addOutput(context: *Context, registry: *wl.Registry, name: u32) !void {
        const wl_output = try registry.bind(name, wl.Output, 3);
        errdefer wl_output.release();
        const node = try gpa.create(std.TailQueue(Output).Node);
        errdefer gpa.destroy(node);
        try node.data.init(context, wl_output, name);
        context.outputs.append(node);
    }
};

const Output = struct {
    wl_output: *wl.Output,
    name: u32,

    main_location: Location,
    main_count: u32,
    main_factor: f64,

    layout: *river.LayoutV2 = undefined,

    fn init(output: *Output, context: *Context, wl_output: *wl.Output, name: u32) !void {
        output.* = .{
            .wl_output = wl_output,
            .name = name,
            .main_location = default_main_location,
            .main_count = default_main_count,
            .main_factor = default_main_factor,
        };
        if (context.initialized) try output.getLayout(context);
    }

    fn getLayout(output: *Output, context: *Context) !void {
        assert(context.initialized);
        output.layout = try context.layout_manager.?.getLayout(output.wl_output, "rivertile");
        output.layout.setListener(*Output, layoutListener, output);
    }

    fn deinit(output: *Output) void {
        output.wl_output.release();
        output.layout.destroy();
    }

    fn layoutListener(layout: *river.LayoutV2, event: river.LayoutV2.Event, output: *Output) void {
        switch (event) {
            .namespace_in_use => fatal("namespace 'rivertile' already in use.", .{}),

            .set_int_value => |ev| {
                if (mem.eql(u8, mem.span(ev.name), "main_count")) {
                    if (ev.value > 0) output.main_count = @intCast(u32, ev.value);
                }
            },
            .mod_int_value => |ev| {
                if (mem.eql(u8, mem.span(ev.name), "main_count")) {
                    const result = @as(i33, output.main_count) + ev.delta;
                    if (result > 0) output.main_count = @intCast(u32, result);
                }
            },

            .set_fixed_value => |ev| {
                if (mem.eql(u8, mem.span(ev.name), "main_factor")) {
                    output.main_factor = math.clamp(ev.value.toDouble(), 0.1, 0.9);
                }
            },
            .mod_fixed_value => |ev| {
                if (mem.eql(u8, mem.span(ev.name), "main_factor")) {
                    const new_value = ev.delta.toDouble() + output.main_factor;
                    output.main_factor = math.clamp(new_value, 0.1, 0.9);
                }
            },

            .set_string_value => |ev| {
                if (mem.eql(u8, mem.span(ev.name), "main_location")) {
                    if (std.meta.stringToEnum(Location, mem.span(ev.value))) |new_location| {
                        output.main_location = new_location;
                    }
                }
            },

            .layout_demand => |ev| {
                const secondary_count = if (ev.view_count > output.main_count)
                    ev.view_count - output.main_count
                else
                    0;

                const usable_width = switch (output.main_location) {
                    .left, .right => ev.usable_width - 2 * outer_padding,
                    .top, .bottom => ev.usable_height - 2 * outer_padding,
                };
                const usable_height = switch (output.main_location) {
                    .left, .right => ev.usable_height - 2 * outer_padding,
                    .top, .bottom => ev.usable_width - 2 * outer_padding,
                };

                // to make things pixel-perfect, we make the first main and first secondary
                // view slightly larger if the height is not evenly divisible
                var main_width: u32 = undefined;
                var main_height: u32 = undefined;
                var main_height_rem: u32 = undefined;

                var secondary_width: u32 = undefined;
                var secondary_height: u32 = undefined;
                var secondary_height_rem: u32 = undefined;

                if (output.main_count > 0 and secondary_count > 0) {
                    main_width = @floatToInt(u32, output.main_factor * @intToFloat(f64, usable_width));
                    main_height = usable_height / output.main_count;
                    main_height_rem = usable_height % output.main_count;

                    secondary_width = usable_width - main_width;
                    secondary_height = usable_height / secondary_count;
                    secondary_height_rem = usable_height % secondary_count;
                } else if (output.main_count > 0) {
                    main_width = usable_width;
                    main_height = usable_height / output.main_count;
                    main_height_rem = usable_height % output.main_count;
                } else if (secondary_width > 0) {
                    main_width = 0;
                    secondary_width = usable_width;
                    secondary_height = usable_height / secondary_count;
                    secondary_height_rem = usable_height % secondary_count;
                }

                var i: u32 = 0;
                while (i < ev.view_count) : (i += 1) {
                    var x: i32 = undefined;
                    var y: i32 = undefined;
                    var width: u32 = undefined;
                    var height: u32 = undefined;

                    if (i < output.main_count) {
                        x = 0;
                        y = @intCast(i32, (i * main_height) + if (i > 0) main_height_rem else 0);
                        width = main_width;
                        height = main_height + if (i == 0) main_height_rem else 0;
                    } else {
                        x = @intCast(i32, main_width);
                        y = @intCast(i32, (i - output.main_count) * secondary_height +
                            if (i > output.main_count) secondary_height_rem else 0);
                        width = secondary_width;
                        height = secondary_height + if (i == output.main_count) secondary_height_rem else 0;
                    }

                    x += @intCast(i32, view_padding);
                    y += @intCast(i32, view_padding);
                    width -= 2 * view_padding;
                    height -= 2 * view_padding;

                    switch (output.main_location) {
                        .left => layout.pushViewDimensions(
                            ev.serial,
                            x + @intCast(i32, outer_padding),
                            y + @intCast(i32, outer_padding),
                            width,
                            height,
                        ),
                        .right => layout.pushViewDimensions(
                            ev.serial,
                            @intCast(i32, usable_width - width) - x + @intCast(i32, outer_padding),
                            y + @intCast(i32, outer_padding),
                            width,
                            height,
                        ),
                        .top => layout.pushViewDimensions(
                            ev.serial,
                            y + @intCast(i32, outer_padding),
                            x + @intCast(i32, outer_padding),
                            height,
                            width,
                        ),
                        .bottom => layout.pushViewDimensions(
                            ev.serial,
                            y + @intCast(i32, outer_padding),
                            @intCast(i32, usable_width - width) - x + @intCast(i32, outer_padding),
                            height,
                            width,
                        ),
                    }
                }

                layout.commit(ev.serial);
            },

            .advertise_view => {},
            .advertise_done => {},
        }
    }
};

pub fn main() !void {
    // https://github.com/ziglang/zig/issues/7807
    const argv: [][*:0]const u8 = std.os.argv;
    const args = Args(0, &[_]FlagDef{
        .{ .name = "-view-padding", .kind = .arg },
        .{ .name = "-outer-padding", .kind = .arg },
        .{ .name = "-main-location", .kind = .arg },
        .{ .name = "-main-count", .kind = .arg },
        .{ .name = "-main-factor", .kind = .arg },
    }).parse(argv[1..]);

    if (args.argFlag("-view-padding")) |raw| {
        view_padding = std.fmt.parseUnsigned(u32, mem.span(raw), 10) catch
            fatal("invalid value '{s}' provided to -view-padding", .{raw});
    }
    if (args.argFlag("-outer-padding")) |raw| {
        outer_padding = std.fmt.parseUnsigned(u32, mem.span(raw), 10) catch
            fatal("invalid value '{s}' provided to -outer-padding", .{raw});
    }
    if (args.argFlag("-main-location")) |raw| {
        default_main_location = std.meta.stringToEnum(Location, mem.span(raw)) orelse
            fatal("invalid value '{s}' provided to -main-location", .{raw});
    }
    if (args.argFlag("-main-count")) |raw| {
        default_main_count = std.fmt.parseUnsigned(u32, mem.span(raw), 10) catch
            fatal("invalid value '{s}' provided to -main-count", .{raw});
    }
    if (args.argFlag("-main-factor")) |raw| {
        default_main_factor = std.fmt.parseFloat(f64, mem.span(raw)) catch
            fatal("invalid value '{s}' provided to -main-factor", .{raw});
    }

    const display = wl.Display.connect(null) catch {
        std.debug.warn("Unable to connect to Wayland server.\n", .{});
        std.os.exit(1);
    };
    defer display.disconnect();

    var context: Context = .{};

    const registry = try display.getRegistry();
    registry.setListener(*Context, registryListener, &context);
    _ = try display.roundtrip();

    if (context.layout_manager == null) {
        fatal("wayland compositor does not support river_layout_v1.\n", .{});
    }

    context.initialized = true;

    var it = context.outputs.first;
    while (it) |node| : (it = node.next) {
        const output = &node.data;
        try output.getLayout(&context);
    }

    while (true) _ = try display.dispatch();
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
    switch (event) {
        .global => |global| {
            if (std.cstr.cmp(global.interface, river.LayoutManagerV2.getInterface().name) == 0) {
                context.layout_manager = registry.bind(global.name, river.LayoutManagerV2, 1) catch return;
            } else if (std.cstr.cmp(global.interface, wl.Output.getInterface().name) == 0) {
                context.addOutput(registry, global.name) catch |err| fatal("failed to bind output: {}", .{err});
            }
        },
        .global_remove => |ev| {
            var it = context.outputs.first;
            while (it) |node| : (it = node.next) {
                const output = &node.data;
                if (output.name == ev.name) {
                    context.outputs.remove(node);
                    output.deinit();
                    gpa.destroy(node);
                    break;
                }
            }
        },
    }
}

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();
    stderr.print("err: " ++ format ++ "\n", args) catch {};
    std.os.exit(1);
}
