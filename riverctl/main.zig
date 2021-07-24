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
const zriver = wayland.client.zriver;

const gpa = std.heap.c_allocator;

const usage =
    \\Usage: riverctl [options]
    \\
    \\  -help                   Print this help message and exit.
    \\  -version                Print the version number and exit.
    \\
    \\
    \\  close                   Close the focused view.
    \\  csd-filter-add          Add app-id to the CSD filter list.
    \\  exit                    Exit the compositor.
    \\  float-filter-add        Add app-id to the float filter list.
    \\  focus-output            Focus the next or previous output.
    \\  focus-view              Focus the next or previous view in the stack.
    \\  move                    Move the focused view.
    \\  resize                  Resize the focused view along the given axis.
    \\  snap                    Snap the focused view.
    \\  send-to-output          Send the focused view to the next/previous
    \\                          output.
    \\  spawn                   Run shell_command using /bin/sh -c.
    \\  swap                    Swap the focused view.
    \\  toggle-float            Toggle the floating state of the focused view.
    \\  toggle-fullscreen       Toggle the fullscreen state of the focused view.
    \\  zoom                    Bump the focused view to the top of the layout
    \\                          stack.
    \\  default-layout          Set the layout namespace of all outputs.
    \\  output-layout           Set the layout namespace of currently focused
    \\                          output.
    \\  send-layout-cmd         Send command to the layout client.
    \\
    \\
    \\  set-focused-tags        Show views with tags corresponding to the set
    \\                          bits of tags.
    \\  set-view-tags           Assign the currently focused view the tags
    \\                          corresponding to the set bits of tags.
    \\  toggle-focused-tags     Toggle visibility of views with tags
    \\                          corresponding to the set bits of tags.
    \\  toggle-view-tags        Toggle the tags of the currently focused view.
    \\  spawn-tagmask           Set a tagmask to filter the tags assigned to
    \\                          newly spawned view.
    \\  focus-previous-tags     Sets tags to their previous value.
    \\
    \\
    \\  declare-mode            Create a new mode.
    \\  enter-mode              Switch to given mode if it exists.
    \\  map                     Run command when key is pressed while modifiers
    \\                          are held down and in the specified mode.
    \\  map-pointer             Move or resize views when button and modifiers
    \\                          are held down while in the specified mode.
    \\  unmap                   Remove the mapping defined by the arguments.
    \\  unmap-pointer           Remove the pointer mapping defined by the
    \\                          arguments.
    \\
    \\
    \\  attach-mode             Configure where new views should attach to
    \\                          the view stack.
    \\  background-color        Set the background color.
    \\  border-color-focused    Set the border color of focused views.
    \\  border-color-unfocused  Set the border color of unfocused views.
    \\  border-width            Set the border width to pixels.
    \\  focus-follows-cursor    Configure the focus behavior when moving cursor.
    \\  set-repeat              Set the keyboard repeat rate and repeat delay.
    \\  set-cursor-warp         Set the cursor warp mode.
    \\  xcursor-theme           Set the xcursor theme.
    \\
    \\
    \\  input                   Configure input devices.
    \\  list-inputs             List all input devices.
    \\  list-input-configs      List all input configurations.
    \\
;

pub const Globals = struct {
    control: ?*zriver.ControlV1 = null,
    seat: ?*wl.Seat = null,
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
            error.SeatNotAdverstised => printErrorExit(
                \\The Wayland server did not advertise any seat.
            , .{}),
            else => return err,
        }
    };
}

fn _main() !void {
    const display = try wl.Display.connect(null);
    const registry = try display.getRegistry();

    var globals = Globals{};

    registry.setListener(*Globals, registryListener, &globals);
    _ = try display.roundtrip();

    const control = globals.control orelse return error.RiverControlNotAdvertised;
    const seat = globals.seat orelse return error.SeatNotAdverstised;

    // This next line is needed cause of https://github.com/ziglang/zig/issues/2622
    const args = os.argv;

    if (mem.eql(u8, mem.span(args[1]), "-help")) {
        try std.io.getStdOut().writeAll(usage);
        std.os.exit(0);
    }

    if (mem.eql(u8, mem.span(args[1]), "-version")) {
        try std.io.getStdOut().writeAll(@import("build_options").version);
        std.os.exit(0);
    }

    // Skip our name, send all other args
    for (args[1..]) |arg| control.addArgument(arg);

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
        .failure => |failure| printErrorExit("Error: {s}\n", .{failure.failure_message}),
    }
}

pub fn printErrorExit(comptime format: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();
    stderr.print("err: " ++ format ++ "\n", args) catch std.os.exit(1);
    std.os.exit(1);
}
