// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const LayerShell = @This();

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;
const zwlr = wayland.server.zwlr;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const LayerShellOutput = @import("LayerShellOutput.zig");
const LayerShellSeat = @import("LayerShellSeat.zig");
const LayerSurface = @import("LayerSurface.zig");
const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Seat = @import("Seat.zig");
const SlotMap = @import("slotmap").SlotMap;

const log = std.log.scoped(.wm);

global: *wl.Global,
wlr_shell: *wlr.LayerShellV1,

/// The layer shell object of the active window manager, if any
objects: wl.list.Head(river.LayerShellV1, null),

surfaces: SlotMap(*LayerSurface) = .empty,

new_surface: wl.Listener(*wlr.LayerSurfaceV1) = .init(handleNewSurface),

pub fn init(layer_shell: *LayerShell) !void {
    layer_shell.* = .{
        .global = try wl.Global.create(server.wl_server, river.LayerShellV1, 1, *LayerShell, layer_shell, bind),
        .wlr_shell = try wlr.LayerShellV1.create(server.wl_server, 4),
        .objects = undefined,
    };
    layer_shell.objects.init();
    layer_shell.wlr_shell.events.new_surface.add(&layer_shell.new_surface);
}

// Use a deinit function rather than listening for the wl_server to be destroyed
// in order to avoid a signal ordering issue. The wlr.LayerShellV1 also listens
// for the wl_server to be destroyed and asserts that the new_surface event has
// no remaining listeners.
pub fn deinit(layer_shell: *LayerShell) void {
    layer_shell.global.destroy();
    layer_shell.new_surface.link.remove();
}

fn bind(client: *wl.Client, layer_shell: *LayerShell, version: u32, id: u32) void {
    const object = river.LayerShellV1.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    object.setHandler(?*anyopaque, handleRequest, handleDestroy, null);
    layer_shell.objects.append(object);
}

fn handleDestroy(object: *river.LayerShellV1, _: ?*anyopaque) void {
    object.getLink().remove();
}

fn handleRequest(
    object: *river.LayerShellV1,
    request: river.LayerShellV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => object.destroy(),
        .get_output => |args| {
            const output_data = args.output.getUserData() orelse return;
            const output: *Output = @ptrCast(@alignCast(output_data));
            if (output.layer_shell.object != null) {
                object.postError(
                    .object_already_created,
                    "river_layer_shell_output_v1 already created",
                );
                return;
            }
            output.layer_shell.createObject(object.getClient(), object.getVersion(), args.id);
        },
        .get_seat => |args| {
            const seat_data = args.seat.getUserData() orelse return;
            const seat: *Seat = @ptrCast(@alignCast(seat_data));
            if (seat.layer_shell.object != null) {
                object.postError(
                    .object_already_created,
                    "river_layer_shell_seat_v1 already created",
                );
                return;
            }
            seat.layer_shell.createObject(object.getClient(), object.getVersion(), args.id);
        },
    }
}

fn supported(layer_shell: *LayerShell) bool {
    const wm_v1 = server.wm.object orelse return false;
    var it = layer_shell.objects.iterator(.forward);
    while (it.next()) |object| {
        if (object.getClient() == wm_v1.getClient()) return true;
    }
    return false;
}

fn handleNewSurface(_: *wl.Listener(*wlr.LayerSurfaceV1), wlr_layer_surface: *wlr.LayerSurfaceV1) void {
    log.debug(
        "new layer surface: namespace {s}, layer {s}, anchor {b:0>4}, size {},{}, margin {},{},{},{}, exclusive_zone {}",
        .{
            wlr_layer_surface.namespace,
            @tagName(wlr_layer_surface.current.layer),
            @as(u32, @bitCast(wlr_layer_surface.current.anchor)),
            wlr_layer_surface.current.desired_width,
            wlr_layer_surface.current.desired_height,
            wlr_layer_surface.current.margin.top,
            wlr_layer_surface.current.margin.right,
            wlr_layer_surface.current.margin.bottom,
            wlr_layer_surface.current.margin.left,
            wlr_layer_surface.current.exclusive_zone,
        },
    );

    if (!server.layer_shell.supported()) {
        log.info("window manager did not bind river_layer_shell_v1, closing layer surface", .{});
        wlr_layer_surface.destroy();
        return;
    }

    if (wlr_layer_surface.output == null) {
        var it = server.om.outputs.iterator(.forward);
        while (it.next()) |output| {
            if (output.layer_shell.requested.default) {
                wlr_layer_surface.output = output.wlr_output;
                break;
            }
        } else {
            if (server.om.outputs.first()) |output| {
                log.info("window manager did not set default layer surface output, choosing arbitrary output", .{});
                wlr_layer_surface.output = output.wlr_output;
            } else {
                log.err("no output available for layer surface '{s}'", .{wlr_layer_surface.namespace});
                wlr_layer_surface.destroy();
                return;
            }
        }
    }

    LayerSurface.create(wlr_layer_surface) catch {
        wlr_layer_surface.resource.postNoMemory();
        return;
    };
}

pub fn updateFocus(_: *LayerShell) void {
    // Find the topmost layer surface (if any) in the top or overlay layers which
    // requests exclusive keyboard interactivity.
    const to_focus = blk: {
        for ([_]zwlr.LayerShellV1.Layer{ .overlay, .top }) |layer| {
            const tree = server.scene.layerSurfaceTree(layer);
            // Iterate in reverse to match rendering order.
            var it = tree.children.iterator(.reverse);
            while (it.next()) |node| {
                assert(node.type == .tree);
                const node_data: *SceneNodeData = @ptrCast(@alignCast(node.data orelse continue));
                const layer_surface = node_data.data.layer_surface;
                const wlr_layer_surface = layer_surface.wlr_layer_surface;
                if (wlr_layer_surface.surface.mapped and
                    wlr_layer_surface.current.keyboard_interactive == .exclusive)
                {
                    break :blk layer_surface;
                }
            }
        }
        break :blk null;
    };

    var it = server.input_manager.seats.iterator(.forward);
    while (it.next()) |seat| {
        if (to_focus) |layer_surface| {
            seat.layer_shell.scheduled.focus = .{ .exclusive = layer_surface.ref };
        } else if (seat.layer_shell.scheduled.focus == .exclusive) {
            seat.layer_shell.scheduled.focus = .none;
        }
    }
}
