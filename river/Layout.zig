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

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Box = @import("Box.zig");
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const LayoutDemand = @import("LayoutDemand.zig");

const log = std.log.scoped(.layout);

layout: *river.LayoutV3,
namespace: []const u8,
output: *Output,

pub fn create(client: *wl.Client, version: u32, id: u32, output: *Output, namespace: []const u8) !void {
    const layout = try river.LayoutV3.create(client, version, id);

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
    if (mem.eql(u8, namespace, output.layoutNamespace())) {
        output.pending.layout = &node.data;
        output.arrangeViews();
    }
}

/// Returns true if the given namespace is already in use on the given output
/// or on another output by a different client.
fn namespaceInUse(namespace: []const u8, output: *Output, client: *wl.Client) bool {
    var output_it = server.root.outputs.first;
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
fn handleRequestInert(layout: *river.LayoutV3, request: river.LayoutV3.Request, _: ?*c_void) void {
    if (request == .destroy) layout.destroy();
}

/// Send a layout demand to the client
pub fn startLayoutDemand(self: *Self, views: u32) void {
    log.debug(
        "starting layout demand '{s}' on output '{s}'",
        .{ self.namespace, mem.sliceTo(&self.output.wlr_output.name, 0) },
    );

    std.debug.assert(self.output.layout_demand == null);
    self.output.layout_demand = LayoutDemand.init(self, views) catch {
        log.err("failed starting layout demand", .{});
        return;
    };

    self.layout.sendLayoutDemand(
        views,
        self.output.usable_box.width,
        self.output.usable_box.height,
        self.output.pending.tags,
        self.output.layout_demand.?.serial,
    );

    server.root.trackLayoutDemands();
}

fn handleRequest(layout: *river.LayoutV3, request: river.LayoutV3.Request, self: *Self) void {
    switch (request) {
        .destroy => layout.destroy(),

        // We receive this event when the client wants to push a view dimension proposal
        // to the layout demand matching the serial.
        .push_view_dimensions => |req| {
            log.debug(
                "layout '{s}' on output '{s}' pushed view dimensions: {} {} {} {}",
                .{ self.namespace, mem.sliceTo(&self.output.wlr_output.name, 0), req.x, req.y, req.width, req.height },
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
                "layout '{s}' on output '{s}' commited",
                .{ self.namespace, mem.sliceTo(&self.output.wlr_output.name, 0) },
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

fn handleDestroy(layout: *river.LayoutV3, self: *Self) void {
    self.destroy();
}

pub fn destroy(self: *Self) void {
    log.debug(
        "destroying layout '{s}' on output '{s}'",
        .{ self.namespace, mem.sliceTo(&self.output.wlr_output.name, 0) },
    );

    // Remove layout from the list
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    self.output.layouts.remove(node);

    // If we are the currently active layout of an output, clean up.
    if (self.output.pending.layout == self) {
        self.output.pending.layout = null;
        if (self.output.layout_demand) |*layout_demand| {
            layout_demand.deinit();
            self.output.layout_demand = null;
            server.root.notifyLayoutDemandDone();
        }
    }

    self.layout.setHandler(?*c_void, handleRequestInert, null, null);

    util.gpa.free(self.namespace);
    util.gpa.destroy(node);
}
