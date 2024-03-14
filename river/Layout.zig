// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 - 2021 The River Developers
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

const Layout = @This();

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const View = @import("View.zig");
const LayoutDemand = @import("LayoutDemand.zig");

const log = std.log.scoped(.layout);

layout_v3: *river.LayoutV3,
namespace: []const u8,
output: *Output,

pub fn create(client: *wl.Client, version: u32, id: u32, output: *Output, namespace: []const u8) !void {
    const layout_v3 = try river.LayoutV3.create(client, version, id);

    if (namespaceInUse(namespace, output, client)) {
        layout_v3.sendNamespaceInUse();
        layout_v3.setHandler(?*anyopaque, handleRequestInert, null, null);
        return;
    }

    const node = try util.gpa.create(std.TailQueue(Layout).Node);
    errdefer util.gpa.destroy(node);
    node.data = .{
        .layout_v3 = layout_v3,
        .namespace = try util.gpa.dupe(u8, namespace),
        .output = output,
    };
    output.layouts.append(node);

    layout_v3.setHandler(*Layout, handleRequest, handleDestroy, &node.data);

    // If the namespace matches that of the output, set the layout as
    // the active one of the output and arrange it.
    if (mem.eql(u8, namespace, output.layoutNamespace())) {
        output.layout = &node.data;
        server.root.applyPending();
    }
}

/// Returns true if the given namespace is already in use on the given output
/// or on another output by a different client.
fn namespaceInUse(namespace: []const u8, output: *Output, client: *wl.Client) bool {
    var output_it = server.root.active_outputs.iterator(.forward);
    while (output_it.next()) |o| {
        var layout_it = output.layouts.first;
        if (o == output) {
            // On this output, no other layout can have our namespace.
            while (layout_it) |layout_node| : (layout_it = layout_node.next) {
                if (mem.eql(u8, namespace, layout_node.data.namespace)) return true;
            }
        } else {
            // Layouts on other outputs may share the namespace, if they come from the same client.
            while (layout_it) |layout_node| : (layout_it = layout_node.next) {
                if (mem.eql(u8, namespace, layout_node.data.namespace) and
                    client != layout_node.data.layout_v3.getClient()) return true;
            }
        }
    }
    return false;
}

/// This exists to handle layouts that have been rendered inert (due to the
/// namespace already being in use) until the client destroys them.
fn handleRequestInert(layout_v3: *river.LayoutV3, request: river.LayoutV3.Request, _: ?*anyopaque) void {
    if (request == .destroy) layout_v3.destroy();
}

/// Send a layout demand to the client
pub fn startLayoutDemand(layout: *Layout, views: u32) void {
    log.debug(
        "starting layout demand '{s}' on output '{s}'",
        .{ layout.namespace, layout.output.wlr_output.name },
    );

    assert(layout.output.inflight.layout_demand == null);
    layout.output.inflight.layout_demand = LayoutDemand.init(layout, views) catch {
        log.err("failed starting layout demand", .{});
        return;
    };

    layout.layout_v3.sendLayoutDemand(
        views,
        @intCast(layout.output.usable_box.width),
        @intCast(layout.output.usable_box.height),
        layout.output.pending.tags,
        layout.output.inflight.layout_demand.?.serial,
    );

    server.root.inflight_layout_demands += 1;
}

fn handleRequest(layout_v3: *river.LayoutV3, request: river.LayoutV3.Request, layout: *Layout) void {
    switch (request) {
        .destroy => layout_v3.destroy(),

        // We receive this event when the client wants to push a view dimension proposal
        // to the layout demand matching the serial.
        .push_view_dimensions => |req| {
            log.debug(
                "layout '{s}' on output '{s}' pushed view dimensions: {} {} {} {}",
                .{ layout.namespace, layout.output.wlr_output.name, req.x, req.y, req.width, req.height },
            );

            if (layout.output.inflight.layout_demand) |*layout_demand| {
                // We can't raise a protocol error when the serial is old/wrong
                // because we do not keep track of old serials server-side.
                // Therefore, simply ignore requests with old/wrong serials.
                if (layout_demand.serial != req.serial) return;
                layout_demand.pushViewDimensions(
                    req.x,
                    req.y,
                    @min(math.maxInt(u31), req.width),
                    @min(math.maxInt(u31), req.height),
                );
            }
        },

        // We receive this event when the client wants to mark the proposed layout
        // of the layout demand matching the serial as done.
        .commit => |req| {
            log.debug(
                "layout '{s}' on output '{s}' commited",
                .{ layout.namespace, layout.output.wlr_output.name },
            );

            if (layout.output.inflight.layout_demand) |*layout_demand| {
                // We can't raise a protocol error when the serial is old/wrong
                // because we do not keep track of old serials server-side.
                // Therefore, simply ignore requests with old/wrong serials.
                if (layout_demand.serial == req.serial) layout_demand.apply(layout);
            }

            const new_name = mem.sliceTo(req.layout_name, 0);
            if (layout.output.layout_name == null or
                !mem.eql(u8, layout.output.layout_name.?, new_name))
            {
                const owned = util.gpa.dupeZ(u8, new_name) catch {
                    log.err("out of memory", .{});
                    return;
                };
                if (layout.output.layout_name) |name| util.gpa.free(name);
                layout.output.layout_name = owned;
                layout.output.status.sendLayoutName(layout.output);
            }
        },
    }
}

fn handleDestroy(_: *river.LayoutV3, layout: *Layout) void {
    layout.destroy();
}

pub fn destroy(layout: *Layout) void {
    log.debug(
        "destroying layout '{s}' on output '{s}'",
        .{ layout.namespace, layout.output.wlr_output.name },
    );

    // Remove layout from the list
    const node = @fieldParentPtr(std.TailQueue(Layout).Node, "data", layout);
    layout.output.layouts.remove(node);

    // If we are the currently active layout of an output, clean up.
    if (layout.output.layout == layout) {
        layout.output.layout = null;
        if (layout.output.inflight.layout_demand) |*layout_demand| {
            layout_demand.deinit();
            layout.output.inflight.layout_demand = null;
            server.root.notifyLayoutDemandDone();
        }

        if (layout.output.layout_name) |name| {
            util.gpa.free(name);
            layout.output.layout_name = null;
            layout.output.status.sendLayoutNameClear(layout.output);
        }
    }

    layout.layout_v3.setHandler(?*anyopaque, handleRequestInert, null, null);

    util.gpa.free(layout.namespace);
    util.gpa.destroy(node);
}
