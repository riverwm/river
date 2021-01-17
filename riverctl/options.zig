// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 The River Developers
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
const zxdg = wayland.client.zxdg;

const root = @import("root");

const Args = @import("args.zig").Args;
const FlagDef = @import("args.zig").FlagDef;
const Globals = @import("main.zig").Globals;
const Output = @import("main.zig").Output;

const ValueType = enum {
    int,
    uint,
    fixed,
    string,
};

const Context = struct {
    display: *wl.Display,
    key: [*:0]const u8,
    raw_value: [*:0]const u8,
    output: ?*Output,
};

pub fn declareOption(display: *wl.Display, globals: *Globals) !void {
    // https://github.com/ziglang/zig/issues/7807
    const argv: [][*:0]const u8 = os.argv;
    const args = Args(3, &[_]FlagDef{.{ .name = "-output", .kind = .arg }}).parse(argv[2..]);
    const key = args.positionals[0];
    const value_type = std.meta.stringToEnum(ValueType, mem.span(args.positionals[1])) orelse
        root.printErrorExit("'{}' is not a valid type, must be int, uint, fixed, or string", .{args.positionals[1]});
    const raw_value = args.positionals[2];
    const output = if (args.argFlag("-output")) |o| try parseOutputName(display, globals, o) else null;

    const options_manager = globals.options_manager orelse return error.RiverOptionsManagerNotAdvertised;
    const handle = try options_manager.getOptionHandle(key, if (output) |o| o.wl_output else null);

    switch (value_type) {
        .int => setIntValueRaw(handle, raw_value),
        .uint => setUintValueRaw(handle, raw_value),
        .fixed => setFixedValueRaw(handle, raw_value),
        .string => handle.setStringValue(raw_value),
    }
    _ = display.flush() catch os.exit(1);
}

fn setIntValueRaw(handle: *zriver.OptionHandleV1, raw_value: [*:0]const u8) void {
    handle.setIntValue(fmt.parseInt(i32, mem.span(raw_value), 10) catch
        root.printErrorExit("{} is not a valid int", .{raw_value}));
}

fn setUintValueRaw(handle: *zriver.OptionHandleV1, raw_value: [*:0]const u8) void {
    handle.setUintValue(fmt.parseInt(u32, mem.span(raw_value), 10) catch
        root.printErrorExit("{} is not a valid uint", .{raw_value}));
}

fn setFixedValueRaw(handle: *zriver.OptionHandleV1, raw_value: [*:0]const u8) void {
    handle.setFixedValue(wl.Fixed.fromDouble(fmt.parseFloat(f64, mem.span(raw_value)) catch
        root.printErrorExit("{} is not a valid fixed", .{raw_value})));
}

pub fn getOption(display: *wl.Display, globals: *Globals) !void {
    // https://github.com/ziglang/zig/issues/7807
    const argv: [][*:0]const u8 = os.argv;
    const args = Args(1, &[_]FlagDef{.{ .name = "-output", .kind = .arg }}).parse(argv[2..]);
    const ctx = Context{
        .display = display,
        .key = args.positionals[0],
        .raw_value = undefined,
        .output = if (args.argFlag("-output")) |o| try parseOutputName(display, globals, o) else null,
    };

    const options_manager = globals.options_manager orelse return error.RiverOptionsManagerNotAdvertised;
    const handle = try options_manager.getOptionHandle(ctx.key, if (ctx.output) |o| o.wl_output else null);
    handle.setListener(*const Context, getOptionListener, &ctx) catch unreachable;

    // We always exit when our listener is called
    while (true) _ = try display.dispatch();
}

pub fn setOption(display: *wl.Display, globals: *Globals) !void {
    // https://github.com/ziglang/zig/issues/7807
    const argv: [][*:0]const u8 = os.argv;
    const args = Args(2, &[_]FlagDef{.{ .name = "-output", .kind = .arg }}).parse(argv[2..]);
    const ctx = Context{
        .display = display,
        .key = args.positionals[0],
        .raw_value = args.positionals[1],
        .output = if (args.argFlag("-output")) |o| try parseOutputName(display, globals, o) else null,
    };

    const options_manager = globals.options_manager orelse return error.RiverOptionsManagerNotAdvertised;
    const handle = try options_manager.getOptionHandle(ctx.key, if (ctx.output) |o| o.wl_output else null);
    handle.setListener(*const Context, setOptionListener, &ctx) catch unreachable;

    // We always exit when our listener is called
    while (true) _ = try display.dispatch();
}

fn parseOutputName(display: *wl.Display, globals: *Globals, output_name: [*:0]const u8) !*Output {
    const output_manager = globals.output_manager orelse return error.XdgOutputNotAdvertised;
    for (globals.outputs.items) |*output| {
        const xdg_output = try output_manager.getXdgOutput(output.wl_output);
        xdg_output.setListener(*Output, xdgOutputListener, output) catch unreachable;
    }
    _ = try display.roundtrip();

    for (globals.outputs.items) |*output| {
        if (mem.eql(u8, output.name, mem.span(output_name))) return output;
    }
    root.printErrorExit("unknown output '{}'", .{output_name});
}

fn xdgOutputListener(xdg_output: *zxdg.OutputV1, event: zxdg.OutputV1.Event, output: *Output) void {
    switch (event) {
        .name => |ev| output.name = std.heap.c_allocator.dupe(u8, mem.span(ev.name)) catch @panic("out of memory"),
        else => {},
    }
}

fn getOptionListener(
    handle: *zriver.OptionHandleV1,
    event: zriver.OptionHandleV1.Event,
    ctx: *const Context,
) void {
    switch (event) {
        .unset => if (ctx.output) |output| {
            root.printErrorExit("option '{}' has not been declared on output '{}'", .{ ctx.key, output.name });
        } else {
            root.printErrorExit("option '{}' has not been declared globally", .{ctx.key});
        },
        .int_value => |ev| printOutputExit("{}", .{ev.value}),
        .uint_value => |ev| printOutputExit("{}", .{ev.value}),
        .fixed_value => |ev| printOutputExit("{d}", .{ev.value.toDouble()}),
        .string_value => |ev| printOutputExit("{}", .{ev.value}),
    }
}

fn printOutputExit(comptime format: []const u8, args: anytype) noreturn {
    const stdout = std.io.getStdOut().writer();
    stdout.print(format ++ "\n", args) catch os.exit(1);
    os.exit(0);
}

fn setOptionListener(
    handle: *zriver.OptionHandleV1,
    event: zriver.OptionHandleV1.Event,
    ctx: *const Context,
) void {
    switch (event) {
        .unset => if (ctx.output) |output| {
            root.printErrorExit("option '{}' has not been declared on output '{}'", .{ ctx.key, output.name });
        } else {
            root.printErrorExit("option '{}' has not been declared globally", .{ctx.key});
        },
        .int_value => |ev| setIntValueRaw(handle, ctx.raw_value),
        .uint_value => |ev| setUintValueRaw(handle, ctx.raw_value),
        .fixed_value => |ev| setFixedValueRaw(handle, ctx.raw_value),
        .string_value => |ev| handle.setStringValue(ctx.raw_value),
    }
    _ = ctx.display.flush() catch os.exit(1);
    os.exit(0);
}
