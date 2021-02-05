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

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zriver = wayland.server.zriver;

const util = @import("util.zig");

const Output = @import("Output.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;

const log = std.log.scoped(.river_status);

output: *Output,
output_status: *zriver.OutputStatusV1,

pub fn init(self: *Self, output: *Output, output_status: *zriver.OutputStatusV1) void {
    self.* = .{ .output = output, .output_status = output_status };

    output_status.setHandler(*Self, handleRequest, handleDestroy, self);

    // Send view/focused tags once on bind.
    self.sendViewTags();
    self.sendFocusedTags();
}

fn handleRequest(output_status: *zriver.OutputStatusV1, request: zriver.OutputStatusV1.Request, self: *Self) void {
    switch (request) {
        .destroy => output_status.destroy(),
    }
}

fn handleDestroy(output_status: *zriver.OutputStatusV1, self: *Self) void {
    const node = @fieldParentPtr(std.SinglyLinkedList(Self).Node, "data", self);
    self.output.status_trackers.remove(node);
}

/// Send the current tags of each view on the output to the client.
pub fn sendViewTags(self: Self) void {
    var view_tags = std.ArrayList(u32).init(util.gpa);
    defer view_tags.deinit();

    var it = self.output.views.first;
    while (it) |node| : (it = node.next) {
        if (node.view.destroying) continue;
        view_tags.append(node.view.current.tags) catch {
            self.output_status.postNoMemory();
            log.crit("out of memory", .{});
            return;
        };
    }

    var wl_array = wl.Array.fromArrayList(u32, view_tags);
    self.output_status.sendViewTags(&wl_array);
}

/// Send the currently focused tags of the output to the client.
pub fn sendFocusedTags(self: Self) void {
    self.output_status.sendFocusedTags(self.output.current.tags);
}
