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

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zriver = wayland.client.zriver;

const SetupContext = struct {
    status_manager: ?*zriver.StatusManagerV1 = null,
    outputs: std.ArrayList(*wl.Output) = std.ArrayList(*wl.Output).init(std.heap.c_allocator),
    seats: std.ArrayList(*wl.Seat) = std.ArrayList(*wl.Seat).init(std.heap.c_allocator),
};

pub fn main() !void {
    const display = try wl.Display.connect(null);
    const registry = try display.getRegistry();

    var context = SetupContext{};

    registry.setListener(*SetupContext, registryListener, &context);
    _ = try display.roundtrip();

    const status_manager = context.status_manager orelse return error.RiverStatusManagerNotAdvertised;

    for (context.outputs.items) |output| {
        const output_status = try status_manager.getRiverOutputStatus(output);
        output_status.setListener(?*c_void, outputStatusListener, null);
    }
    for (context.seats.items) |seat| {
        const seat_status = try status_manager.getRiverSeatStatus(seat);
        seat_status.setListener(?*c_void, seatStatusListener, null);
    }
    context.outputs.deinit();
    context.seats.deinit();

    // Loop forever, listening for new events.
    while (true) _ = try display.dispatch();
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *SetupContext) void {
    switch (event) {
        .global => |global| {
            if (std.cstr.cmp(global.interface, zriver.StatusManagerV1.getInterface().name) == 0) {
                context.status_manager = registry.bind(global.name, zriver.StatusManagerV1, 1) catch return;
            } else if (std.cstr.cmp(global.interface, wl.Seat.getInterface().name) == 0) {
                const seat = registry.bind(global.name, wl.Seat, 1) catch return;
                context.seats.append(seat) catch @panic("out of memory");
            } else if (std.cstr.cmp(global.interface, wl.Output.getInterface().name) == 0) {
                const output = registry.bind(global.name, wl.Output, 1) catch return;
                context.outputs.append(output) catch @panic("out of memory");
            }
        },
        .global_remove => {},
    }
}

fn outputStatusListener(output_status: *zriver.OutputStatusV1, event: zriver.OutputStatusV1.Event, data: ?*c_void) void {
    switch (event) {
        .focused_tags => |focused_tags| std.debug.warn("Focused tags: {b:0>10}\n", .{focused_tags.tags}),
        .view_tags => |view_tags| {
            std.debug.warn("View tags:\n", .{});
            for (view_tags.tags.slice(u32)) |t| std.debug.warn("{b:0>10}\n", .{t});
        },
    }
}

fn seatStatusListener(seat_status: *zriver.SeatStatusV1, event: zriver.SeatStatusV1.Event, data: ?*c_void) void {
    switch (event) {
        .focused_output => |focused_output| std.debug.warn("Output id {} focused\n", .{
            @ptrCast(*wl.Proxy, focused_output.output orelse return).getId(),
        }),
        .unfocused_output => |unfocused_output| std.debug.warn("Output id {} focused\n", .{
            @ptrCast(*wl.Proxy, unfocused_output.output orelse return).getId(),
        }),
        .focused_view => |focused_view| std.debug.warn("Focused view title: {}\n", .{focused_view.title}),
    }
}
