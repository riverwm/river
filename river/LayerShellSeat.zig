// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const LayerShellSeat = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const LayerSurface = @import("LayerSurface.zig");
const Seat = @import("Seat.zig");

const log = std.log.scoped(.wm);

const Focus = union(enum) {
    exclusive: LayerSurface.Ref,
    non_exclusive: LayerSurface.Ref,
    none,
};

object: ?*river.LayerShellSeatV1 = null,

scheduled: struct {
    focus: Focus = .none,
} = .{},
sent: struct {
    focus: Focus = .none,
} = .{},
requested: struct {} = .{},

pub fn createObject(
    shell_seat: *LayerShellSeat,
    client: *wl.Client,
    version: u32,
    id: u32,
) void {
    assert(shell_seat.object == null);
    shell_seat.object = river.LayerShellSeatV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    shell_seat.object.?.setHandler(*LayerShellSeat, handleRequest, handleDestroy, shell_seat);
    server.wm.dirtyWindowing();
}

pub fn makeInert(shell_seat: *LayerShellSeat) void {
    if (shell_seat.object) |object| {
        object.setHandler(?*anyopaque, handleRequestInert, null, null);
        shell_seat.object = null;
    }
}

fn handleRequestInert(
    object: *river.LayerShellSeatV1,
    request: river.LayerShellSeatV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) object.destroy();
}

fn handleDestroy(_: *river.LayerShellSeatV1, shell_seat: *LayerShellSeat) void {
    shell_seat.object = null;
}

fn handleRequest(
    object: *river.LayerShellSeatV1,
    request: river.LayerShellSeatV1.Request,
    shell_seat: *LayerShellSeat,
) void {
    assert(shell_seat.object == object);
    switch (request) {
        .destroy => object.destroy(),
    }
}

pub fn manageStart(shell_seat: *LayerShellSeat) void {
    if (@as(std.meta.Tag(Focus), shell_seat.scheduled.focus) != shell_seat.sent.focus) {
        if (shell_seat.object) |shell_seat_v1| {
            switch (shell_seat.scheduled.focus) {
                .exclusive => shell_seat_v1.sendFocusExclusive(),
                .non_exclusive => shell_seat_v1.sendFocusNonExclusive(),
                .none => shell_seat_v1.sendFocusNone(),
            }
        }
    }
    shell_seat.sent.focus = shell_seat.scheduled.focus;
    if (shell_seat.scheduled.focus == .non_exclusive) {
        shell_seat.scheduled.focus = .none;
    }
}
