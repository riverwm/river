// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 - 2021 The River Developers
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
const mem = std.mem;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const util = @import("util.zig");

const Box = @import("Box.zig");
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const LayoutDemand = @import("LayoutDemand.zig");

const log = std.log.scoped(.layout);

layout: *river.LayoutV1,
namespace: []const u8,
output: *Output,

pub fn create(client: *wl.Client, version: u32, id: u32, output: *Output, namespace: []const u8) !void {
    const layout = try river.LayoutV1.create(client, version, id);

    if (namespaceInUse(namespace, output, client)) {
        layout.sendNamespaceInUse();
        layout.setHandler(?*c_void, handleRequestInert, null, null);
        return;
    }

    const node = try util.gpa.create(std.TailQueue(Self).Node);
    errdefer util.gpa.destroy(node);
    node.data = .{
        .layout = layout,
        .namespace = try util.gpa.dupe(u8, namespace),
        .output = output,
    };
    output.layouts.append(node);

    layout.setHandler(*Self, handleRequest, handleDestroy, &node.data);

    // If the namespace matches that of the output, set the layout as
    // the active one of the output and arrange it.
    if (output.layout_option.get().string) |current_layout| {
        if (mem.eql(u8, namespace, mem.span(current_layout))) {
            output.pending.layout = &node.data;
            output.arrangeViews();
        }
    }
}

/// Returns true if the given namespace is already in use on the given output
/// or on another output by a different client.
fn namespaceInUse(namespace: []const u8, output: *Output, client: *wl.Client) bool {
    var output_it = output.root.outputs.first;
    while (output_it) |output_node| : (output_it = output_node.next) {
        var layout_it = output_node.data.layouts.first;
        if (output_node.data.wlr_output == output.wlr_output) {
            // On this output, no other layout can have our namespace.
            while (layout_it) |layout_node| : (layout_it = layout_node.next) {
                if (mem.eql(u8, namespace, layout_node.data.namespace)) return true;
            }
        } else {
            // Layouts on other outputs may share the namespace, if they come from the same client.
            while (layout_it) |layout_node| : (layout_it = layout_node.next) {
                if (mem.eql(u8, namespace, layout_node.data.namespace) and
                    client != layout_node.data.layout.getClient()) return true;
            }
        }
    }
    return false;
}

/// This exists to handle layouts that have been rendered inert (due to the
/// namespace already being in use) until the client destroys them.
fn handleRequestInert(layout: *river.LayoutV1, request: river.LayoutV1.Request, _: ?*c_void) void {
    if (request == .destroy) layout.destroy();
}

/// Send a layout demand to the client
pub fn startLayoutDemand(self: *Self, views: u32) void {
    log.debug(
        "starting layout demand '{}' on output '{}'",
        .{ self.namespace, self.output.wlr_output.name },
    );

    std.debug.assert(self.output.layout_demand == null);
    self.output.layout_demand = LayoutDemand.init(self, views) catch {
        log.err("failed starting layout demand", .{});
        return;
    };
    const serial = self.output.layout_demand.?.serial;

    // Then we let the client know that we require a layout
    self.layout.sendLayoutDemand(
        views,
        self.output.usable_box.width,
        self.output.usable_box.height,
        self.output.pending.tags,
        serial,
    );

    // And finally we advertise all visible views
    var it = ViewStack(View).iter(self.output.views.first, .forward, self.output.pending.tags, Output.arrangeFilter);
    while (it.next()) |view| {
        self.layout.sendAdvertiseView(view.pending.tags, view.getAppId(), serial);
    }
    self.layout.sendAdvertiseDone(serial);

    self.output.root.trackLayoutDemands();
}

fn handleRequest(layout: *river.LayoutV1, request: river.LayoutV1.Request, self: *Self) void {
    switch (request) {
        .destroy => layout.destroy(),

        // Parameters of the layout changed. We only care about this, if the
        // layout is currently in use, in which case we rearrange the output.
        .parameters_changed => if (self == self.output.pending.layout) self.output.arrangeViews(),

        // We receive this event when the client wants to push a view dimension proposal
        // to the layout demand matching the serial.
        .push_view_dimensions => |req| {
            log.debug(
                "layout '{}' on output '{}' pushed view dimensions: {} {} {} {}",
                .{ self.namespace, self.output.wlr_output.name, req.x, req.y, req.width, req.height },
            );

            if (self.output.layout_demand) |*layout_demand| {
                // We can't raise a protocol error when the serial is old/wrong
                // because we do not keep track of old serials server-side.
                // Therefore, simply ignore requests with old/wrong serials.
                if (layout_demand.serial != req.serial) return;
                layout_demand.pushViewDimensions(self.output, req.x, req.y, req.width, req.height);
            }
        },

        // We receive this event when the client wants to mark the proposed layout
        // of the layout demand matching the serial as done.
        .commit => |req| {
            log.debug(
                "layout '{}' on output '{}' commited",
                .{ self.namespace, self.output.wlr_output.name },
            );

            if (self.output.layout_demand) |*layout_demand| {
                // We can't raise a protocol error when the serial is old/wrong
                // because we do not keep track of old serials server-side.
                // Therefore, simply ignore requests with old/wrong serials.
                if (layout_demand.serial == req.serial) layout_demand.apply(self);
            }
        },
    }
}

fn handleDestroy(layout: *river.LayoutV1, self: *Self) void {
    log.debug(
        "destroying layout '{}' on output '{}'",
        .{ self.namespace, self.output.wlr_output.name },
    );

    // Remove layout from the list
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    self.output.layouts.remove(node);

    // If we are the currently active layout of an output,  clean up. The output
    // will always end up with no layout at this point, so we directly start the
    // transaction.
    if (self == self.output.pending.layout) {
        self.output.pending.layout = null;
        self.output.arrangeViews();
        self.output.root.startTransaction();
    }

    util.gpa.free(self.namespace);
    util.gpa.destroy(node);
}
