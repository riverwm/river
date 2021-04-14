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
const math = std.math;
const mem = std.mem;
const fmt = std.fmt;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;
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
    const args = Args(3, &[_]FlagDef{}).parse(argv[2..]);

    const key = args.positionals[0];
    const value_type = std.meta.stringToEnum(ValueType, mem.span(args.positionals[1])) orelse {
        root.printErrorExit(
            "'{}' is not a valid type, must be int, uint, fixed, or string",
            .{args.positionals[1]},
        );
    };
    const raw_value = args.positionals[2];

    const options_manager = globals.options_manager orelse return error.RiverOptionsManagerNotAdvertised;

    switch (value_type) {
        .int => options_manager.declareIntOption(key, parseInt(raw_value)),
        .uint => options_manager.declareUintOption(key, parseUint(raw_value)),
        .fixed => options_manager.declareFixedOption(key, parseFixed(raw_value)),
        .string => options_manager.declareStringOption(key, raw_value),
    }

    _ = try display.flush();
}

fn parseInt(raw_value: [*:0]const u8) i32 {
    return fmt.parseInt(i32, mem.span(raw_value), 10) catch
        root.printErrorExit("{} is not a valid int", .{raw_value});
}

fn parseUint(raw_value: [*:0]const u8) u32 {
    return fmt.parseInt(u32, mem.span(raw_value), 10) catch
        root.printErrorExit("{} is not a valid uint", .{raw_value});
}

fn parseFixed(raw_value: [*:0]const u8) wl.Fixed {
    return wl.Fixed.fromDouble(fmt.parseFloat(f64, mem.span(raw_value)) catch
        root.printErrorExit("{} is not a valid fixed", .{raw_value}));
}

pub fn getOption(display: *wl.Display, globals: *Globals) !void {
    // https://github.com/ziglang/zig/issues/7807
    const argv: [][*:0]const u8 = os.argv;
    const args = Args(1, &[_]FlagDef{
        .{ .name = "-output", .kind = .arg },
        .{ .name = "-focused-output", .kind = .boolean },
    }).parse(argv[2..]);

    const output = if (args.argFlag("-output")) |o|
        try parseOutputName(display, globals, o)
    else if (args.boolFlag("-focused-output"))
        try getFocusedOutput(display, globals)
    else
        null;

    const ctx = Context{
        .display = display,
        .key = args.positionals[0],
        .raw_value = undefined,
        .output = output,
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
    const args = Args(2, &[_]FlagDef{
        .{ .name = "-output", .kind = .arg },
        .{ .name = "-focused-output", .kind = .boolean },
    }).parse(argv[2..]);

    const output = if (args.argFlag("-output")) |o|
        try parseOutputName(display, globals, o)
    else if (args.boolFlag("-focused-output"))
        try getFocusedOutput(display, globals)
    else
        null;

    const ctx = Context{
        .display = display,
        .key = args.positionals[0],
        .raw_value = args.positionals[1],
        .output = output,
    };

    const options_manager = globals.options_manager orelse return error.RiverOptionsManagerNotAdvertised;
    const handle = try options_manager.getOptionHandle(ctx.key, if (ctx.output) |o| o.wl_output else null);
    handle.setListener(*const Context, setOptionListener, &ctx) catch unreachable;

    // We always exit when our listener is called
    while (true) _ = try display.dispatch();
}

pub fn unsetOption(display: *wl.Display, globals: *Globals) !void {
    // https://github.com/ziglang/zig/issues/7807
    const argv: [][*:0]const u8 = os.argv;
    const args = Args(1, &[_]FlagDef{
        .{ .name = "-output", .kind = .arg },
        .{ .name = "-focused-output", .kind = .boolean },
    }).parse(argv[2..]);

    const output = if (args.argFlag("-output")) |o|
        try parseOutputName(display, globals, o)
    else if (args.boolFlag("-focused-output"))
        try getFocusedOutput(display, globals)
    else
        root.printErrorExit("unset requires either -output or -focused-output", .{});

    const key = args.positionals[0];

    const options_manager = globals.options_manager orelse return error.RiverOptionsManagerNotAdvertised;

    options_manager.unsetOption(key, output.wl_output);

    _ = try display.flush();
}

pub fn modOption(display: *wl.Display, globals: *Globals) !void {
    // https://github.com/ziglang/zig/issues/7807
    const argv: [][*:0]const u8 = os.argv;
    const args = Args(2, &[_]FlagDef{
        .{ .name = "-output", .kind = .arg },
        .{ .name = "-focused-output", .kind = .boolean },
    }).parse(argv[2..]);

    const output = if (args.argFlag("-output")) |o|
        try parseOutputName(display, globals, o)
    else if (args.boolFlag("-focused-output"))
        try getFocusedOutput(display, globals)
    else
        null;

    const ctx = Context{
        .display = display,
        .key = args.positionals[0],
        .raw_value = args.positionals[1],
        .output = output,
    };

    const options_manager = globals.options_manager orelse return error.RiverOptionsManagerNotAdvertised;
    const handle = try options_manager.getOptionHandle(ctx.key, if (ctx.output) |o| o.wl_output else null);
    handle.setListener(*const Context, modOptionListener, &ctx) catch unreachable;

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

fn getFocusedOutput(display: *wl.Display, globals: *Globals) !*Output {
    const status_manager = globals.status_manager orelse return error.RiverStatusManagerNotAdvertised;
    const seat = globals.seat orelse return error.SeatNotAdverstised;
    const seat_status = try status_manager.getRiverSeatStatus(seat);
    var result: ?*wl.Output = null;
    seat_status.setListener(*?*wl.Output, seatStatusListener, &result) catch unreachable;
    _ = try display.roundtrip();
    const wl_output = if (result) |output| output else return error.NoOutputFocused;
    for (globals.outputs.items) |*output| {
        if (output.wl_output == wl_output) return output;
    } else unreachable;
}

fn seatStatusListener(seat_status: *zriver.SeatStatusV1, event: zriver.SeatStatusV1.Event, result: *?*wl.Output) void {
    switch (event) {
        .focused_output => |ev| result.* = ev.output,
        .unfocused_output, .focused_view => {},
    }
}

fn getOptionListener(
    handle: *river.OptionHandleV2,
    event: river.OptionHandleV2.Event,
    ctx: *const Context,
) void {
    switch (event) {
        .undeclared => root.printErrorExit("option '{}' has not been declared", .{ctx.key}),
        .int_value => |ev| printOutputExit("{}", .{ev.value}),
        .uint_value => |ev| printOutputExit("{}", .{ev.value}),
        .fixed_value => |ev| printOutputExit("{d}", .{ev.value.toDouble()}),
        .string_value => |ev| if (ev.value) |s| printOutputExit("{}", .{s}) else os.exit(0),
    }
}

fn printOutputExit(comptime format: []const u8, args: anytype) noreturn {
    const stdout = std.io.getStdOut().writer();
    stdout.print(format ++ "\n", args) catch os.exit(1);
    os.exit(0);
}

fn setOptionListener(
    handle: *river.OptionHandleV2,
    event: river.OptionHandleV2.Event,
    ctx: *const Context,
) void {
    switch (event) {
        .undeclared => root.printErrorExit("option '{}' has not been declared", .{ctx.key}),
        .int_value => |ev| handle.setIntValue(parseInt(ctx.raw_value)),
        .uint_value => |ev| handle.setUintValue(parseUint(ctx.raw_value)),
        .fixed_value => |ev| handle.setFixedValue(parseFixed(ctx.raw_value)),
        .string_value => |ev| handle.setStringValue(if (ctx.raw_value[0] == 0) null else ctx.raw_value),
    }
    _ = ctx.display.flush() catch os.exit(1);
    os.exit(0);
}

fn modOptionListener(
    handle: *river.OptionHandleV2,
    event: river.OptionHandleV2.Event,
    ctx: *const Context,
) void {
    switch (event) {
        .undeclared => root.printErrorExit("option '{}' has not been declared", .{ctx.key}),
        .int_value => |ev| modIntValueRaw(handle, ev.value, ctx.raw_value),
        .uint_value => |ev| modUintValueRaw(handle, ev.value, ctx.raw_value),
        .fixed_value => |ev| modFixedValueRaw(handle, ev.value, ctx.raw_value),
        .string_value => root.printErrorExit("can not modify string options, use set-option to overwrite them", .{}),
    }
    _ = ctx.display.flush() catch os.exit(1);
    os.exit(0);
}

fn modIntValueRaw(handle: *river.OptionHandleV2, current: i32, raw_value: [*:0]const u8) void {
    const mod = fmt.parseInt(i32, mem.span(raw_value), 10) catch
        root.printErrorExit("{} is not a valid int modifier", .{raw_value});
    const new_value = math.add(i32, current, mod) catch
        root.printErrorExit("provided value of {d} would overflow option if added", .{mod});
    handle.setIntValue(new_value);
}

fn modUintValueRaw(handle: *river.OptionHandleV2, current: u32, raw_value: [*:0]const u8) void {
    // We need to allow negative mod values, but the value of the option may
    // never be below zero.
    const mod = fmt.parseInt(i32, mem.span(raw_value), 10) catch
        root.printErrorExit("{} is not a valid uint modifier", .{raw_value});
    const new = @intCast(i32, current) + mod;
    handle.setUintValue(if (new < 0) 0 else @intCast(u32, new));
}

fn modFixedValueRaw(handle: *river.OptionHandleV2, current: wl.Fixed, raw_value: [*:0]const u8) void {
    const mod = fmt.parseFloat(f64, mem.span(raw_value)) catch
        root.printErrorExit("{} is not a valid fixed modifier", .{raw_value});
    handle.setFixedValue(wl.Fixed.fromDouble(current.toDouble() + mod));
}
