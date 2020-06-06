// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
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

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("river-status-unstable-v1-client-protocol.h");
});

const wl_registry_listener = c.wl_registry_listener{
    .global = handleGlobal,
    .global_remove = handleGlobalRemove,
};

const river_output_status_listener = c.zriver_output_status_v1_listener{
    .focused_tags = handleFocusedTags,
    .view_tags = handleViewTags,
};

const river_seat_status_listener = c.zriver_seat_status_v1_listener{
    .focused_output = handleFocusedOutput,
    .unfocused_output = handleUnfocusedOutput,
    .focused_view = handleFocusedView,
};

var river_status_manager: ?*c.zriver_status_manager_v1 = null;

var outputs = std.ArrayList(*c.wl_output).init(std.heap.c_allocator);
var seats = std.ArrayList(*c.wl_seat).init(std.heap.c_allocator);

pub fn main() !void {
    const wl_display = c.wl_display_connect(null) orelse return error.CantConnectToDisplay;
    const wl_registry = c.wl_display_get_registry(wl_display);

    if (c.wl_registry_add_listener(wl_registry, &wl_registry_listener, null) < 0)
        return error.FailedToAddListener;
    if (c.wl_display_roundtrip(wl_display) < 0) return error.RoundtripFailed;

    if (river_status_manager == null) return error.RiverStatusManagerNotAdvertised;

    for (outputs.items) |wl_output| createOutputStatus(wl_output);
    for (seats.items) |wl_seat| createSeatStatus(wl_seat);
    outputs.deinit();
    seats.deinit();

    // Loop forever, listening for new events.
    while (true) if (c.wl_display_dispatch(wl_display) < 0) return error.DispatchFailed;
}

fn handleGlobal(
    data: ?*c_void,
    wl_registry: ?*c.wl_registry,
    name: u32,
    interface: ?[*:0]const u8,
    version: u32,
) callconv(.C) void {
    // Global advertisement order is not defined, so save any outputs or seats
    // advertised before the river_status_manager.
    if (std.cstr.cmp(interface.?, @ptrCast([*:0]const u8, c.zriver_status_manager_v1_interface.name.?)) == 0) {
        river_status_manager = @ptrCast(
            *c.zriver_status_manager_v1,
            c.wl_registry_bind(wl_registry, name, &c.zriver_status_manager_v1_interface, version),
        );
    } else if (std.cstr.cmp(interface.?, @ptrCast([*:0]const u8, c.wl_output_interface.name.?)) == 0) {
        const wl_output = @ptrCast(
            *c.wl_output,
            c.wl_registry_bind(wl_registry, name, &c.wl_output_interface, version),
        );
        outputs.append(wl_output) catch @panic("out of memory");
    } else if (std.cstr.cmp(interface.?, @ptrCast([*:0]const u8, c.wl_seat_interface.name.?)) == 0) {
        const wl_seat = @ptrCast(
            *c.wl_seat,
            c.wl_registry_bind(wl_registry, name, &c.wl_seat_interface, version),
        );
        seats.append(wl_seat) catch @panic("out of memory");
    }
}

fn createOutputStatus(wl_output: *c.wl_output) void {
    const river_output_status = c.zriver_status_manager_v1_get_river_output_status(
        river_status_manager.?,
        wl_output,
    );
    _ = c.zriver_output_status_v1_add_listener(
        river_output_status,
        &river_output_status_listener,
        null,
    );
}

fn createSeatStatus(wl_seat: *c.wl_seat) void {
    const river_seat_status = c.zriver_status_manager_v1_get_river_seat_status(
        river_status_manager.?,
        wl_seat,
    );
    _ = c.zriver_seat_status_v1_add_listener(river_seat_status, &river_seat_status_listener, null);
}

fn handleGlobalRemove(data: ?*c_void, wl_registry: ?*c.wl_registry, name: u32) callconv(.C) void {
    // Ignore the event
}

fn handleFocusedTags(
    data: ?*c_void,
    output_status: ?*c.zriver_output_status_v1,
    tags: u32,
) callconv(.C) void {
    std.debug.warn("Focused tags: {b:0>10}\n", .{tags});
}

fn handleViewTags(
    data: ?*c_void,
    output_status: ?*c.zriver_output_status_v1,
    tags: ?*c.wl_array,
) callconv(.C) void {
    std.debug.warn("View tags:\n", .{});
    var offset: usize = 0;
    while (offset < tags.?.size) : (offset += @sizeOf(u32)) {
        const ptr = @ptrCast([*]u8, tags.?.data) + offset;
        std.debug.warn("{b:0>10}\n", .{std.mem.bytesToValue(u32, ptr[0..4])});
    }
}

fn handleFocusedOutput(
    data: ?*c_void,
    seat_status: ?*c.zriver_seat_status_v1,
    wl_output: ?*c.wl_output,
) callconv(.C) void {
    std.debug.warn("Output id {} focused\n", .{c.wl_proxy_get_id(@ptrCast(*c.wl_proxy, wl_output))});
}

fn handleUnfocusedOutput(
    data: ?*c_void,
    seat_status: ?*c.zriver_seat_status_v1,
    wl_output: ?*c.wl_output,
) callconv(.C) void {
    std.debug.warn("Output id {} unfocused\n", .{c.wl_proxy_get_id(@ptrCast(*c.wl_proxy, wl_output))});
}

fn handleFocusedView(
    data: ?*c_void,
    seat_status: ?*c.zriver_seat_status_v1,
    title: ?[*:0]const u8,
) callconv(.C) void {
    std.debug.warn("Focused view title: {}\n", .{title.?});
}
