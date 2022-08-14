// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
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

    // Send view/focused/urgent tags once on bind.
    self.sendViewTags();
    self.sendFocusedTags(output.current.tags);

    var urgent_tags: u32 = 0;
    var view_it = self.output.views.first;
    while (view_it) |node| : (view_it = node.next) {
        if (node.view.current.urgent) urgent_tags |= node.view.current.tags;
    }
    self.sendUrgentTags(urgent_tags);

    if (output.layout_name) |name| {
        self.sendLayoutName(name);
    }
}

pub fn destroy(self: *Self) void {
    const node = @fieldParentPtr(std.SinglyLinkedList(Self).Node, "data", self);
    self.output.status_trackers.remove(node);
    self.output_status.setHandler(*Self, handleRequest, null, self);
    util.gpa.destroy(node);
}

fn handleRequest(output_status: *zriver.OutputStatusV1, request: zriver.OutputStatusV1.Request, _: *Self) void {
    switch (request) {
        .destroy => output_status.destroy(),
    }
}

fn handleDestroy(_: *zriver.OutputStatusV1, self: *Self) void {
    self.destroy();
}

/// Send the current tags of each view on the output to the client.
pub fn sendViewTags(self: Self) void {
    var view_tags = std.ArrayList(u32).init(util.gpa);
    defer view_tags.deinit();

    var it = self.output.views.first;
    while (it) |node| : (it = node.next) {
        if (node.view.surface == null) continue;
        view_tags.append(node.view.current.tags) catch {
            self.output_status.postNoMemory();
            log.err("out of memory", .{});
            return;
        };
    }

    var wl_array = wl.Array.fromArrayList(u32, view_tags);
    self.output_status.sendViewTags(&wl_array);
}

pub fn sendFocusedTags(self: Self, tags: u32) void {
    self.output_status.sendFocusedTags(tags);
}

pub fn sendUrgentTags(self: Self, tags: u32) void {
    if (self.output_status.getVersion() >= 2) {
        self.output_status.sendUrgentTags(tags);
    }
}

pub fn sendLayoutName(self: Self, name: [:0]const u8) void {
    if (self.output_status.getVersion() >= 4) {
        self.output_status.sendLayoutName(name);
    }
}

pub fn sendLayoutNameClear(self: Self) void {
    if (self.output_status.getVersion() >= 4) {
        self.output_status.sendLayoutNameClear();
    }
}
