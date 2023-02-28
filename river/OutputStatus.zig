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

const OutputStatus = @This();

const std = @import("std");
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.server.wl;
const zriver = wayland.server.zriver;

const util = @import("util.zig");

const Output = @import("Output.zig");
const View = @import("View.zig");

const log = std.log.scoped(.river_status);

resources: wl.list.Head(zriver.OutputStatusV1, null),
view_tags: std.ArrayListUnmanaged(u32) = .{},
focused_tags: u32 = 0,
urgent_tags: u32 = 0,

pub fn init(status: *OutputStatus) void {
    status.* = .{
        .resources = undefined,
    };
    status.resources.init();
}

pub fn add(status: *OutputStatus, resource: *zriver.OutputStatusV1, output: *Output) void {
    resource.setHandler(?*anyopaque, handleRequest, handleDestroy, null);

    var wl_array: wl.Array = .{
        .size = status.view_tags.items.len * @sizeOf(u32),
        .alloc = status.view_tags.items.len * @sizeOf(u32),
        .data = status.view_tags.items.ptr,
    };
    resource.sendViewTags(&wl_array);
    resource.sendFocusedTags(status.focused_tags);
    if (resource.getVersion() >= 2) resource.sendUrgentTags(status.urgent_tags);
    if (resource.getVersion() >= 4) {
        if (output.layout_name) |name| resource.sendLayoutName(name);
    }

    status.resources.append(resource);
}

pub fn deinit(status: *OutputStatus) void {
    {
        var it = status.resources.safeIterator(.forward);
        while (it.next()) |resource| {
            resource.setHandler(?*anyopaque, handleRequest, null, null);
            resource.getLink().remove();
        }
    }
    status.view_tags.deinit(util.gpa);
}

fn handleRequest(resource: *zriver.OutputStatusV1, request: zriver.OutputStatusV1.Request, _: ?*anyopaque) void {
    switch (request) {
        .destroy => resource.destroy(),
    }
}

fn handleDestroy(resource: *zriver.OutputStatusV1, _: ?*anyopaque) void {
    resource.getLink().remove();
}

pub fn handleTransactionCommit(status: *OutputStatus, output: *Output) void {
    status.sendViewTags(output);
    status.sendFocusedTags(output);
    status.sendUrgentTags(output);
}

fn sendViewTags(status: *OutputStatus, output: *Output) void {
    var dirty: bool = false;
    {
        var it = output.inflight.wm_stack.iterator(.forward);
        var i: usize = 0;
        while (it.next()) |view| : (i += 1) {
            assert(view.inflight.tags == view.current.tags);
            if (status.view_tags.items.len <= i) {
                dirty = true;
                _ = status.view_tags.addOne(util.gpa) catch {
                    log.err("out of memory", .{});
                    return;
                };
            } else if (view.inflight.tags != status.view_tags.items[i]) {
                dirty = true;
            }
            status.view_tags.items[i] = view.inflight.tags;
        }

        if (i != status.view_tags.items.len) {
            assert(i < status.view_tags.items.len);
            status.view_tags.items.len = i;
            dirty = true;
        }
    }

    if (dirty) {
        var wl_array: wl.Array = .{
            .size = status.view_tags.items.len * @sizeOf(u32),
            .alloc = status.view_tags.items.len * @sizeOf(u32),
            .data = status.view_tags.items.ptr,
        };
        var it = status.resources.iterator(.forward);
        while (it.next()) |resource| resource.sendViewTags(&wl_array);
    }
}

fn sendFocusedTags(status: *OutputStatus, output: *Output) void {
    assert(output.inflight.tags == output.current.tags);
    if (status.focused_tags != output.inflight.tags) {
        status.focused_tags = output.inflight.tags;

        var it = status.resources.iterator(.forward);
        while (it.next()) |resource| resource.sendFocusedTags(status.focused_tags);
    }
}

fn sendUrgentTags(status: *OutputStatus, output: *Output) void {
    var urgent_tags: u32 = 0;
    {
        var it = output.inflight.wm_stack.iterator(.forward);
        while (it.next()) |view| {
            if (view.current.urgent) urgent_tags |= view.current.tags;
        }
    }

    if (status.urgent_tags != urgent_tags) {
        status.urgent_tags = urgent_tags;

        var it = status.resources.iterator(.forward);
        while (it.next()) |resource| {
            if (resource.getVersion() >= 2) resource.sendUrgentTags(urgent_tags);
        }
    }
}

pub fn sendLayoutName(status: *OutputStatus, output: *Output) void {
    assert(output.layout_name != null);

    var it = status.resources.iterator(.forward);
    while (it.next()) |resource| {
        if (resource.getVersion() >= 4) resource.sendLayoutName(output.layout_name.?);
    }
}

pub fn sendLayoutNameClear(status: *OutputStatus, output: *Output) void {
    assert(output.layout_name == null);

    var it = status.resources.iterator(.forward);
    while (it.next()) |resource| {
        if (resource.getVersion() >= 4) resource.sendLayoutNameClear();
    }
}
