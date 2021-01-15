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
const os = std.os;
const mem = std.mem;
const fmt = std.fmt;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zriver = wayland.client.zriver;

const SetupContext = struct {
    options_manager: ?*zriver.OptionsManagerV1 = null,
    outputs: std.ArrayList(*wl.Output) = std.ArrayList(*wl.Output).init(std.heap.c_allocator),
};

const ValueType = enum {
    int,
    uint,
    fixed,
    string,
};

/// Disclaimer, the output handling implemented here is by no means robust. A
/// proper client should likely use xdg-output to identify outputs by name.
///
/// Usage: ./options <key> output_num|NULL [<value_type> <value>]
/// Examples:
///     ./options foo
///     ./options foo NULL uint 42
///     ./options foo 1 string ziggy
pub fn main() !void {
    const display = try wl.Display.connect(null);
    const registry = try display.getRegistry();

    var context = SetupContext{};

    registry.setListener(*SetupContext, registryListener, &context) catch unreachable;
    _ = try display.roundtrip();

    const options_manager = context.options_manager orelse return error.RiverOptionsManagerNotAdvertised;

    const key = os.argv[1];
    const output = if (mem.eql(u8, "NULL", mem.span(os.argv[2])))
        null
    else
        context.outputs.items[fmt.parseInt(u32, mem.span(os.argv[2]), 10) catch return error.InvalidOutput];
    const handle = try options_manager.getOptionHandle(key, output);
    handle.setListener([*:0]u8, optionListener, key) catch unreachable;

    if (os.argv.len > 3) {
        const value_type = std.meta.stringToEnum(ValueType, mem.span(os.argv[3])) orelse return error.InvalidType;
        switch (value_type) {
            .int => handle.setIntValue(fmt.parseInt(i32, mem.span(os.argv[4]), 10) catch return error.InvalidInt),
            .uint => handle.setUintValue(fmt.parseInt(u32, mem.span(os.argv[4]), 10) catch return error.InvalidUint),
            .fixed => handle.setFixedValue(wl.Fixed.fromDouble(fmt.parseFloat(f64, mem.span(os.argv[4])) catch return error.InvalidFixed)),
            .string => handle.setStringValue(os.argv[4]),
        }
    }

    // Loop forever, listening for new events.
    while (true) _ = try display.dispatch();
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *SetupContext) void {
    switch (event) {
        .global => |global| {
            if (std.cstr.cmp(global.interface, zriver.OptionsManagerV1.getInterface().name) == 0) {
                context.options_manager = registry.bind(global.name, zriver.OptionsManagerV1, 1) catch return;
            } else if (std.cstr.cmp(global.interface, wl.Output.getInterface().name) == 0) {
                const output = registry.bind(global.name, wl.Output, 1) catch return;
                context.outputs.append(output) catch @panic("out of memory");
            }
        },
        .global_remove => {},
    }
}

fn optionListener(handle: *zriver.OptionHandleV1, event: zriver.OptionHandleV1.Event, key: [*:0]const u8) void {
    switch (event) {
        .unset => std.debug.print("option '{}' unset\n", .{key}),
        .int_value => |ev| std.debug.print("option '{}' of type int has value {}\n", .{ key, ev.value }),
        .uint_value => |ev| std.debug.print("option '{}' of type uint has value {}\n", .{ key, ev.value }),
        .fixed_value => |ev| std.debug.print("option '{}' of type fixed has value {}\n", .{ key, ev.value.toDouble() }),
        .string_value => |ev| std.debug.print("option '{}' of type string has value {}\n", .{ key, ev.value }),
    }
}
