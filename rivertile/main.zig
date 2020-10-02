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
//

//
// This is an implementation of the  default "tiled" layout of dwm and the
// 3 other orientations thereof. This code is written with the left
// orientation in mind and then the input/output values are adjusted to apply
// the necessary transformations to derive the other 3.
//
// With 4 views and one main, the left layout looks something like this:
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
//

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zriver = wayland.client.zriver;
const river = wayland.client.river;

const gpa = std.heap.c_allocator;

const Context = struct {
    running: bool = true,
    layout_manager: ?*river.LayoutManagerV1 = null,
    options_manager: ?*zriver.OptionsManagerV1 = null,
    outputs: std.TailQueue(Output) = .{},

    pub fn addOutput(self: *Context, registry: *wl.Registry, name: u32) !void {
        const output = try registry.bind(name, wl.Output, 3);
        const node = try gpa.create(std.TailQueue(Output).Node);
        node.data.init(self, output);
        self.outputs.append(node);
    }

    pub fn destroyAllOutputs(self: *Context) void {
        while (self.outputs.pop()) |node| {
            node.data.deinit();
            gpa.destroy(node);
        }
    }

    pub fn configureAllOutputs(self: *Context) void {
        var it = self.outputs.first;
        while (it) |node| : (it = node.next) {
            node.data.configure(self);
        }
    }
};

const Option = struct {
    pub const Value = union(enum) {
        unset: void,
        double: f64,
        uint: u32,
    };

    handle: ?*zriver.OptionHandleV1 = null,
    value: Value = .unset,
    output: *Output = undefined,

    pub fn init(self: *Option, output: *Output, comptime key: [*:0]const u8, initial: Value) !void {
        self.* = .{
            .value = initial,
            .output = output,
            .handle = try output.context.options_manager.?.getOptionHandle(
                key,
                output.output,
            ),
        };
        self.handle.?.setListener(*Option, optionListener, self) catch |err| {
            self.handle.?.destroy();
            self.handle = null;
            return err;
        };
    }

    pub fn deinit(self: *Option) void {
        if (self.handle) |handle| handle.destroy();
    }

    fn optionListener(handle: *zriver.OptionHandleV1, event: zriver.OptionHandleV1.Event, self: *Option) void {
        switch (event) {
            .unset => switch (self.value) {
                .uint => handle.setUintValue(self.value.uint),
                .double => handle.setFixedValue(wl.Fixed.fromDouble(self.value.double)),
                else => unreachable,
            },
            .int_value => {},
            .uint_value => |data| self.value = .{ .uint = data.value },
            .fixed_value => |data| self.value = .{ .double = data.value.toDouble() },
            .string_value => {},
        }
        if (self.output.top.layout) |layout| layout.parametersChanged();
        if (self.output.right.layout) |layout| layout.parametersChanged();
        if (self.output.bottom.layout) |layout| layout.parametersChanged();
        if (self.output.left.layout) |layout| layout.parametersChanged();
    }

    pub fn getValueOrElse(self: *Option, comptime T: type, comptime otherwise: T) T {
        switch (T) {
            u32 => return if (self.value == .uint) self.value.uint else otherwise,
            f64 => return if (self.value == .double) self.value.double else otherwise,
            else => @compileError("Unsupported type for Option.getValueOrElse()"),
        }
    }
};

const Output = struct {
    context: *Context,
    output: *wl.Output,

    top: Layout = undefined,
    right: Layout = undefined,
    bottom: Layout = undefined,
    left: Layout = undefined,

    main_amount: Option = .{},
    main_factor: Option = .{},
    view_padding: Option = .{},
    outer_padding: Option = .{},

    configured: bool = false,

    pub fn init(self: *Output, context: *Context, wl_output: *wl.Output) void {
        self.* = .{
            .output = wl_output,
            .context = context,
        };
        self.configure(context);
    }

    pub fn deinit(self: *Output) void {
        self.output.release();

        if (self.configured) {
            self.top.deinit();
            self.right.deinit();
            self.bottom.deinit();
            self.left.deinit();

            self.main_amount.deinit();
            self.main_factor.deinit();
            self.view_padding.deinit();
            self.outer_padding.deinit();
        }
    }

    pub fn configure(self: *Output, context: *Context) void {
        if (self.configured) return;
        if (context.layout_manager == null) return;
        if (context.options_manager == null) return;

        self.configured = true;

        self.main_amount.init(self, "main_amount", .{ .uint = 1 }) catch {};
        self.main_factor.init(self, "main_factor", .{ .double = 0.6 }) catch {};
        self.view_padding.init(self, "view_padding", .{ .uint = 10 }) catch {};
        self.outer_padding.init(self, "outer_padding", .{ .uint = 10 }) catch {};

        self.top.init(self, .top) catch {};
        self.right.init(self, .right) catch {};
        self.bottom.init(self, .bottom) catch {};
        self.left.init(self, .left) catch {};
    }
};

const Layout = struct {
    output: *Output,
    layout: ?*river.LayoutV1,
    orientation: Orientation,

    const Orientation = enum {
        top,
        right,
        bottom,
        left,
    };

    pub fn init(self: *Layout, output: *Output, orientation: Orientation) !void {
        self.output = output;
        self.orientation = orientation;
        self.layout = try output.context.layout_manager.?.getLayout(
            self.output.output,
            self.getNamespace(),
        );
        self.layout.?.setListener(*Layout, layoutListener, self) catch |err| {
            self.layout.?.destroy();
            self.layout = null;
            return err;
        };
    }

    fn getNamespace(self: *Layout) [*:0]const u8 {
        return switch (self.orientation) {
            .top => "tile-top",
            .right => "tile-right",
            .bottom => "tile-bottom",
            .left => "tile-left",
        };
    }

    pub fn deinit(self: *Layout) void {
        if (self.layout) |layout| {
            layout.destroy();
            self.layout = null;
        }
    }

    fn layoutListener(layout: *river.LayoutV1, event: river.LayoutV1.Event, self: *Layout) void {
        switch (event) {
            .namespace_in_use => {
                std.debug.warn("{}: Namespace already in use.\n", .{self.getNamespace()});
                self.deinit();
            },

            .layout_demand => |data| {
                const main_amount = self.output.main_amount.getValueOrElse(u32, 1);
                const main_factor = std.math.clamp(self.output.main_factor.getValueOrElse(f64, 0.6), 0.1, 0.9);
                const view_padding = self.output.view_padding.getValueOrElse(u32, 0);
                const outer_padding = self.output.outer_padding.getValueOrElse(u32, 0);

                const secondary_count = if (data.view_count > main_amount)
                    data.view_count - main_amount
                else
                    0;

                const usable_width = if (self.orientation == .left or self.orientation == .right)
                    data.usable_width - (2 * outer_padding)
                else
                    data.usable_height - (2 * outer_padding);
                const usable_height = if (self.orientation == .left or self.orientation == .right)
                    data.usable_height - (2 * outer_padding)
                else
                    data.usable_width - (2 * outer_padding);

                // to make things pixel-perfect, we make the first main and first secondary
                // view slightly larger if the height is not evenly divisible
                var main_width: u32 = undefined;
                var main_height: u32 = undefined;
                var main_height_rem: u32 = undefined;

                var secondary_width: u32 = undefined;
                var secondary_height: u32 = undefined;
                var secondary_height_rem: u32 = undefined;

                if (main_amount > 0 and secondary_count > 0) {
                    main_width = @floatToInt(u32, main_factor * @intToFloat(f64, usable_width));
                    main_height = usable_height / main_amount;
                    main_height_rem = usable_height % main_amount;

                    secondary_width = usable_width - main_width;
                    secondary_height = usable_height / secondary_count;
                    secondary_height_rem = usable_height % secondary_count;
                } else if (main_amount > 0) {
                    main_width = usable_width;
                    main_height = usable_height / main_amount;
                    main_height_rem = usable_height % main_amount;
                } else if (secondary_width > 0) {
                    main_width = 0;
                    secondary_width = usable_width;
                    secondary_height = usable_height / secondary_count;
                    secondary_height_rem = usable_height % secondary_count;
                }

                var i: u32 = 0;
                while (i < data.view_count) : (i += 1) {
                    var x: i32 = undefined;
                    var y: i32 = undefined;
                    var width: u32 = undefined;
                    var height: u32 = undefined;

                    if (i < main_amount) {
                        x = 0;
                        y = @intCast(i32, (i * main_height) + if (i > 0) main_height_rem else 0);
                        width = main_width;
                        height = main_height + if (i == 0) main_height_rem else 0;
                    } else {
                        x = @intCast(i32, main_width);
                        y = @intCast(i32, (i - main_amount) * secondary_height +
                            if (i > main_amount) secondary_height_rem else 0);
                        width = secondary_width;
                        height = secondary_height + if (i == main_amount) secondary_height_rem else 0;
                    }

                    x += @intCast(i32, view_padding);
                    y += @intCast(i32, view_padding);
                    width -= 2 * view_padding;
                    height -= 2 * view_padding;

                    switch (self.orientation) {
                        .left => layout.pushViewDimensions(
                            data.serial,
                            x + @intCast(i32, outer_padding),
                            y + @intCast(i32, outer_padding),
                            width,
                            height,
                        ),
                        .right => layout.pushViewDimensions(
                            data.serial,
                            @intCast(i32, usable_width - width) - x + @intCast(i32, outer_padding),
                            y + @intCast(i32, outer_padding),
                            width,
                            height,
                        ),
                        .top => layout.pushViewDimensions(
                            data.serial,
                            y + @intCast(i32, outer_padding),
                            x + @intCast(i32, outer_padding),
                            height,
                            width,
                        ),
                        .bottom => layout.pushViewDimensions(
                            data.serial,
                            y + @intCast(i32, outer_padding),
                            @intCast(i32, usable_width - width) - x + @intCast(i32, outer_padding),
                            height,
                            width,
                        ),
                    }
                }

                layout.commit(data.serial);
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
    try registry.setListener(*Context, registryListener, &context);
    _ = try display.roundtrip();

    if (context.layout_manager == null) {
        std.debug.warn("Wayland server does not support river_layout_unstable_v1.\n", .{});
        std.os.exit(1);
    }

    if (context.options_manager == null) {
        std.debug.warn("Wayland server does not support river_options_unstable_v1.\n", .{});
        std.os.exit(1);
    }

    context.configureAllOutputs();
    defer context.destroyAllOutputs();

    while (context.running) {
        _ = try display.dispatch();
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
    switch (event) {
        .global => |global| {
            if (std.cstr.cmp(global.interface, river.LayoutManagerV1.getInterface().name) == 0) {
                context.layout_manager = registry.bind(global.name, river.LayoutManagerV1, 1) catch return;
            } else if (std.cstr.cmp(global.interface, zriver.OptionsManagerV1.getInterface().name) == 0) {
                context.options_manager = registry.bind(global.name, zriver.OptionsManagerV1, 1) catch return;
            } else if (std.cstr.cmp(global.interface, wl.Output.getInterface().name) == 0) {
                context.addOutput(registry, global.name) catch {
                    std.debug.warn("Failed to bind output.\n", .{});
                    context.running = false;
                };
            }
        },
        .global_remove => |global| {},
    }
}
