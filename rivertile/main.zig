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
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Location = enum {
    top,
    right,
    bottom,
    left,
};

const default_main_location: Location = .left;
const default_main_count = 1;
const default_main_factor = 0.6;
const default_view_padding = 6;
const default_outer_padding = 6;

/// We don't free resources on exit, only when output globals are removed.
const gpa = std.heap.c_allocator;

const Context = struct {
    initialized: bool = false,
    layout_manager: ?*river.LayoutManagerV1 = null,
    options_manager: ?*river.OptionsManagerV2 = null,
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

fn Option(comptime key: [:0]const u8, comptime T: type, comptime default: T) type {
    return struct {
        const Self = @This();
        output: *Output,
        handle: *river.OptionHandleV2,
        value: T = default,

        fn init(option: *Self, context: *Context, output: *Output) !void {
            option.* = .{
                .output = output,
                .handle = try context.options_manager.?.getOptionHandle(key, output.wl_output),
            };
            option.handle.setListener(*Self, optionListener, option) catch unreachable;
        }

        fn deinit(option: *Self) void {
            option.handle.destroy();
            option.* = undefined;
        }

        fn optionListener(handle: *river.OptionHandleV2, event: river.OptionHandleV2.Event, option: *Self) void {
            const prev_value = option.value;
            assert(event != .undeclared); // We declare all options used in main()
            switch (T) {
                u32 => switch (event) {
                    .uint_value => |ev| option.value = ev.value,
                    else => std.log.err("expected value of uint type for " ++ key ++
                        " option, falling back to default", .{}),
                },
                f64 => switch (event) {
                    .fixed_value => |ev| option.value = ev.value.toDouble(),
                    else => std.log.err("expected value of fixed type for " ++ key ++
                        " option, falling back to default", .{}),
                },
                Location => switch (event) {
                    .string_value => |ev| if (ev.value) |value| {
                        if (std.meta.stringToEnum(Location, mem.span(value))) |location| {
                            option.value = location;
                        } else {
                            std.log.err(
                                \\invalid main_location "{s}", must be "top", "bottom", "left", or "right"
                            , .{value});
                        }
                    },
                    else => std.log.err("expected value of string type for " ++ key ++
                        " option, falling back to default", .{}),
                },
                else => unreachable,
            }
            if (option.value != prev_value) option.output.layout.parametersChanged();
        }
    };
}

const Output = struct {
    wl_output: *wl.Output,
    name: u32,

    main_location: Option("main_location", Location, default_main_location) = undefined,
    main_count: Option("main_count", u32, default_main_count) = undefined,
    main_factor: Option("main_factor", f64, default_main_factor) = undefined,
    view_padding: Option("view_padding", u32, default_view_padding) = undefined,
    outer_padding: Option("outer_padding", u32, default_outer_padding) = undefined,

    layout: *river.LayoutV1 = undefined,

    fn init(output: *Output, context: *Context, wl_output: *wl.Output, name: u32) !void {
        output.* = .{ .wl_output = wl_output, .name = name };
        if (context.initialized) try output.initOptionsAndLayout(context);
    }

    fn initOptionsAndLayout(output: *Output, context: *Context) !void {
        assert(context.initialized);
        try output.main_location.init(context, output);
        errdefer output.main_location.deinit();
        try output.main_count.init(context, output);
        errdefer output.main_count.deinit();
        try output.main_factor.init(context, output);
        errdefer output.main_factor.deinit();
        try output.view_padding.init(context, output);
        errdefer output.view_padding.deinit();
        try output.outer_padding.init(context, output);
        errdefer output.outer_padding.deinit();

        output.layout = try context.layout_manager.?.getLayout(output.wl_output, "rivertile");
        output.layout.setListener(*Output, layoutListener, output) catch unreachable;
    }

    fn deinit(output: *Output) void {
        output.wl_output.release();

        output.main_count.deinit();
        output.main_factor.deinit();
        output.view_padding.deinit();
        output.outer_padding.deinit();

        output.layout.destroy();
    }

    fn layoutListener(layout: *river.LayoutV1, event: river.LayoutV1.Event, output: *Output) void {
        switch (event) {
            .namespace_in_use => fatal("namespace 'rivertile' already in use.", .{}),

            .layout_demand => |ev| {
                const secondary_count = if (ev.view_count > output.main_count.value)
                    ev.view_count - output.main_count.value
                else
                    0;

                const usable_width = switch (output.main_location.value) {
                    .left, .right => ev.usable_width - (2 * output.outer_padding.value),
                    .top, .bottom => ev.usable_height - (2 * output.outer_padding.value),
                };
                const usable_height = switch (output.main_location.value) {
                    .left, .right => ev.usable_height - (2 * output.outer_padding.value),
                    .top, .bottom => ev.usable_width - (2 * output.outer_padding.value),
                };

                // to make things pixel-perfect, we make the first main and first secondary
                // view slightly larger if the height is not evenly divisible
                var main_width: u32 = undefined;
                var main_height: u32 = undefined;
                var main_height_rem: u32 = undefined;

                var secondary_width: u32 = undefined;
                var secondary_height: u32 = undefined;
                var secondary_height_rem: u32 = undefined;

                if (output.main_count.value > 0 and secondary_count > 0) {
                    main_width = @floatToInt(u32, output.main_factor.value * @intToFloat(f64, usable_width));
                    main_height = usable_height / output.main_count.value;
                    main_height_rem = usable_height % output.main_count.value;

                    secondary_width = usable_width - main_width;
                    secondary_height = usable_height / secondary_count;
                    secondary_height_rem = usable_height % secondary_count;
                } else if (output.main_count.value > 0) {
                    main_width = usable_width;
                    main_height = usable_height / output.main_count.value;
                    main_height_rem = usable_height % output.main_count.value;
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

                    if (i < output.main_count.value) {
                        x = 0;
                        y = @intCast(i32, (i * main_height) + if (i > 0) main_height_rem else 0);
                        width = main_width;
                        height = main_height + if (i == 0) main_height_rem else 0;
                    } else {
                        x = @intCast(i32, main_width);
                        y = @intCast(i32, (i - output.main_count.value) * secondary_height +
                            if (i > output.main_count.value) secondary_height_rem else 0);
                        width = secondary_width;
                        height = secondary_height + if (i == output.main_count.value) secondary_height_rem else 0;
                    }

                    x += @intCast(i32, output.view_padding.value);
                    y += @intCast(i32, output.view_padding.value);
                    width -= 2 * output.view_padding.value;
                    height -= 2 * output.view_padding.value;

                    switch (output.main_location.value) {
                        .left => layout.pushViewDimensions(
                            ev.serial,
                            x + @intCast(i32, output.outer_padding.value),
                            y + @intCast(i32, output.outer_padding.value),
                            width,
                            height,
                        ),
                        .right => layout.pushViewDimensions(
                            ev.serial,
                            @intCast(i32, usable_width - width) - x + @intCast(i32, output.outer_padding.value),
                            y + @intCast(i32, output.outer_padding.value),
                            width,
                            height,
                        ),
                        .top => layout.pushViewDimensions(
                            ev.serial,
                            y + @intCast(i32, output.outer_padding.value),
                            x + @intCast(i32, output.outer_padding.value),
                            height,
                            width,
                        ),
                        .bottom => layout.pushViewDimensions(
                            ev.serial,
                            y + @intCast(i32, output.outer_padding.value),
                            @intCast(i32, usable_width - width) - x + @intCast(i32, output.outer_padding.value),
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
    const display = wl.Display.connect(null) catch {
        std.debug.warn("Unable to connect to Wayland server.\n", .{});
        std.os.exit(1);
    };
    defer display.disconnect();

    var context: Context = .{};

    const registry = try display.getRegistry();
    registry.setListener(*Context, registryListener, &context) catch unreachable;
    _ = try display.roundtrip();

    if (context.layout_manager == null) {
        fatal("wayland compositor does not support river_layout_v1.\n", .{});
    }
    if (context.options_manager == null) {
        fatal("wayland compositor does not support river_options_v2.\n", .{});
    }

    // TODO: should be @tagName(default_main_location), https://github.com/ziglang/zig/issues/3779
    context.options_manager.?.declareStringOption("main_location", "left");
    context.options_manager.?.declareUintOption("main_count", default_main_count);
    context.options_manager.?.declareFixedOption("main_factor", wl.Fixed.fromDouble(default_main_factor));
    context.options_manager.?.declareUintOption("view_padding", default_view_padding);
    context.options_manager.?.declareUintOption("outer_padding", default_outer_padding);

    context.initialized = true;

    var it = context.outputs.first;
    while (it) |node| : (it = node.next) {
        const output = &node.data;
        try output.initOptionsAndLayout(&context);
    }

    while (true) _ = try display.dispatch();
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
    switch (event) {
        .global => |global| {
            if (std.cstr.cmp(global.interface, river.LayoutManagerV1.getInterface().name) == 0) {
                context.layout_manager = registry.bind(global.name, river.LayoutManagerV1, 1) catch return;
            } else if (std.cstr.cmp(global.interface, river.OptionsManagerV2.getInterface().name) == 0) {
                context.options_manager = registry.bind(global.name, river.OptionsManagerV2, 1) catch return;
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

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.os.exit(1);
}
