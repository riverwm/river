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
const log = @import("log.zig");
const util = @import("util.zig");

const Output = @import("Output.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;

const implementation = c.struct_zriver_output_status_v1_interface{
    .destroy = destroy,
};

output: *Output,
wl_resource: *c.wl_resource,

pub fn init(self: *Self, output: *Output, wl_resource: *c.wl_resource) void {
    self.output = output;
    self.wl_resource = wl_resource;

    c.wl_resource_set_implementation(wl_resource, &implementation, self, handleResourceDestroy);

    // Send view/focused tags once on bind.
    self.sendViewTags();
    self.sendFocusedTags();
}

fn handleResourceDestroy(wl_resource: ?*c.wl_resource) callconv(.C) void {
    const self = util.voidCast(Self, @ptrCast(*c_void, c.wl_resource_get_user_data(wl_resource)));
    const node = @fieldParentPtr(std.SinglyLinkedList(Self).Node, "data", self);
    self.output.status_trackers.remove(node);
}

fn destroy(wl_client: ?*c.wl_client, wl_resource: ?*c.wl_resource) callconv(.C) void {
    c.wl_resource_destroy(wl_resource);
}

/// Send the current tags of each view on the output to the client.
pub fn sendViewTags(self: Self) void {
    var view_tags = std.ArrayList(u32).init(util.gpa);
    defer view_tags.deinit();

    var it = ViewStack(View).iterator(self.output.views.first, std.math.maxInt(u32));
    while (it.next()) |node|
        view_tags.append(node.view.current.tags) catch {
        c.wl_resource_post_no_memory(self.wl_resource);
        log.crit(.river_status, "out of memory", .{});
        return;
    };

    var wl_array = c.wl_array{
        .size = view_tags.items.len * @sizeOf(u32),
        .alloc = view_tags.capacity * @sizeOf(u32),
        .data = view_tags.items.ptr,
    };
    c.zriver_output_status_v1_send_view_tags(self.wl_resource, &wl_array);
}

/// Send the currently focused tags of the output to the client.
pub fn sendFocusedTags(self: Self) void {
    c.zriver_output_status_v1_send_focused_tags(self.wl_resource, self.output.current.tags);
}
