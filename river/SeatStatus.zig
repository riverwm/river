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

const Self = @This();

const std = @import("std");

const c = @import("c.zig");
const util = @import("util.zig");

const Seat = @import("Seat.zig");
const Output = @import("Output.zig");
const View = @import("View.zig");

const FocusState = enum {
    focused,
    unfocused,
};

const implementation = c.struct_zriver_seat_status_v1_interface{
    .destroy = destroy,
};

seat: *Seat,
wl_resource: *c.wl_resource,

pub fn init(self: *Self, seat: *Seat, wl_resource: *c.wl_resource) void {
    self.seat = seat;
    self.wl_resource = wl_resource;

    c.wl_resource_set_implementation(wl_resource, &implementation, self, handleResourceDestroy);

    // Send focused output/view once on bind
    self.sendOutput(.focused);
    self.sendFocusedView();
}

fn handleResourceDestroy(wl_resource: ?*c.wl_resource) callconv(.C) void {
    const self = util.voidCast(Self, c.wl_resource_get_user_data(wl_resource).?);
    const node = @fieldParentPtr(std.SinglyLinkedList(Self).Node, "data", self);
    self.seat.status_trackers.remove(node);
}

fn destroy(wl_client: ?*c.wl_client, wl_resource: ?*c.wl_resource) callconv(.C) void {
    c.wl_resource_destroy(wl_resource);
}

pub fn sendOutput(self: Self, state: FocusState) void {
    const wl_client = c.wl_resource_get_client(self.wl_resource);
    const output_resources = &self.seat.focused_output.wlr_output.resources;
    var output_resource = c.wl_resource_from_link(output_resources.next);
    while (c.wl_resource_get_link(output_resource) != output_resources) : (output_resource =
        c.wl_resource_from_link(c.wl_resource_get_link(output_resource).*.next))
    {
        if (c.wl_resource_get_client(output_resource) == wl_client) switch (state) {
            .focused => c.zriver_seat_status_v1_send_focused_output(self.wl_resource, output_resource),
            .unfocused => c.zriver_seat_status_v1_send_unfocused_output(self.wl_resource, output_resource),
        };
    }
}

pub fn sendFocusedView(self: Self) void {
    c.zriver_seat_status_v1_send_focused_view(self.wl_resource, if (self.seat.focused_view) |v|
        v.getTitle()
    else
        "");
}
