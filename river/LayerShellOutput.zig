// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const LayerShellOutput = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;
const zwlr = wayland.server.zwlr;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");

const log = std.log.scoped(.wm);

object: ?*river.LayerShellOutputV1 = null,

scheduled: struct {
    non_exclusive_area: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
} = .{},
sent: struct {
    non_exclusive_area: ?wlr.Box = null,
} = .{},
requested: struct {
    default: bool = false,
} = .{},

pub fn createObject(
    shell_output: *LayerShellOutput,
    client: *wl.Client,
    version: u32,
    id: u32,
) void {
    assert(shell_output.object == null);
    shell_output.object = river.LayerShellOutputV1.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    shell_output.object.?.setHandler(*LayerShellOutput, handleRequest, handleDestroy, shell_output);
    server.wm.dirtyWindowing();
}

pub fn makeInert(shell_output: *LayerShellOutput) void {
    if (shell_output.object) |object| {
        object.setHandler(?*anyopaque, handleRequestInert, null, null);
        handleDestroy(object, shell_output);
    }
}

fn handleRequestInert(
    object: *river.LayerShellOutputV1,
    request: river.LayerShellOutputV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) object.destroy();
}

fn handleDestroy(_: *river.LayerShellOutputV1, shell_output: *LayerShellOutput) void {
    shell_output.object = null;
    shell_output.sent = .{};
    shell_output.requested = .{};
}

fn handleRequest(
    layer_shell_output_v1: *river.LayerShellOutputV1,
    request: river.LayerShellOutputV1.Request,
    shell_output: *LayerShellOutput,
) void {
    assert(shell_output.object == layer_shell_output_v1);
    switch (request) {
        .destroy => layer_shell_output_v1.destroy(),
        .set_default => {
            var it = server.om.outputs.iterator(.forward);
            while (it.next()) |output| {
                output.layer_shell.requested.default = false;
            }
            shell_output.requested.default = true;
        },
    }
}

pub fn arrange(shell_output: *LayerShellOutput) void {
    const output: *Output = @fieldParentPtr("layer_shell", shell_output);
    shell_output.scheduled.non_exclusive_area = output.scheduled.box();
    sendConfigures(output, .exclusive);
    sendConfigures(output, .non_exclusive);
    if (!std.meta.eql(
        shell_output.sent.non_exclusive_area,
        shell_output.scheduled.non_exclusive_area,
    )) {
        server.wm.dirtyWindowing();
    }
}

fn sendConfigures(
    output: *Output,
    mode: enum { exclusive, non_exclusive },
) void {
    const output_width, const output_height = output.scheduled.dimensions();
    const output_box = output.scheduled.box();
    for ([_]zwlr.LayerShellV1.Layer{ .background, .bottom, .top, .overlay }) |layer| {
        const tree = server.scene.layerSurfaceTree(layer);
        var it = tree.children.safeIterator(.forward);
        while (it.next()) |node| {
            assert(node.type == .tree);
            const node_data: *SceneNodeData = @ptrCast(@alignCast(node.data orelse continue));
            const layer_surface = node_data.data.layer_surface;
            if (!layer_surface.wlr_layer_surface.surface.mapped and
                !layer_surface.wlr_layer_surface.initial_commit)
            {
                continue;
            }
            if (layer_surface.wlr_layer_surface.output != output.wlr_output) {
                continue;
            }
            const current = layer_surface.wlr_layer_surface.current;
            const exclusive = current.exclusive_zone > 0;
            if (exclusive != (mode == .exclusive)) {
                continue;
            }
            {
                var new_area = output.layer_shell.scheduled.non_exclusive_area;
                layer_surface.scene_layer_surface.configure(&output_box, &new_area);
                // Clients can request bogus exclusive zones larger than the output
                // dimensions and river must handle this gracefully. It seems reasonable
                // to close layer shell clients that would cause the usable area of the
                // output to become less than half the width/height of its full dimensions.
                if (new_area.width < output_width / 2 or new_area.height < output_height / 2) {
                    layer_surface.wlr_layer_surface.destroy();
                    continue;
                }
                output.layer_shell.scheduled.non_exclusive_area = new_area;
            }
            const x = layer_surface.scene_layer_surface.tree.node.x;
            const y = layer_surface.scene_layer_surface.tree.node.y;
            layer_surface.popup_tree.node.setPosition(x, y);
            layer_surface.scene_layer_surface.tree.node.subsurfaceTreeSetClip(&.{
                .x = -(x - output.scheduled.x),
                .y = -(y - output.scheduled.y),
                .width = output_width,
                .height = output_height,
            });
        }
    }
}

pub fn manageStart(shell_output: *LayerShellOutput) void {
    const output: *Output = @fieldParentPtr("layer_shell", shell_output);
    assert(output.scheduled.state == .enabled or output.scheduled.state == .disabled_soft);

    const scheduled_box = output.scheduled.box();
    const sent_box = output.sent.box();

    if (!std.meta.eql(scheduled_box, sent_box)) {
        shell_output.scheduled.non_exclusive_area = scheduled_box;
        sendConfigures(output, .exclusive);
        sendConfigures(output, .non_exclusive);
    }
    if (!std.meta.eql(
        shell_output.sent.non_exclusive_area,
        shell_output.scheduled.non_exclusive_area,
    )) {
        if (shell_output.object) |layer_shell_output_v1| {
            layer_shell_output_v1.sendNonExclusiveArea(
                shell_output.scheduled.non_exclusive_area.x,
                shell_output.scheduled.non_exclusive_area.y,
                shell_output.scheduled.non_exclusive_area.width,
                shell_output.scheduled.non_exclusive_area.height,
            );
            shell_output.sent.non_exclusive_area = shell_output.scheduled.non_exclusive_area;
        }
    }
}
