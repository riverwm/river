// SPDX-FileCopyrightText: © 2026 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const XkbBindingsSeat = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");

const log = std.log.scoped(.wm);

object: ?*river.XkbBindingsSeatV1 = null,

scheduled: struct {
    ate_unbound_key: bool = false,
} = .{},
requested: struct {
    next_key_change: enum {
        none,
        ensure_eaten,
        cancel_ensure_eaten,
    } = .none,
} = .{},

ensure_next_key_eaten: bool = false,

pub fn createObject(
    bindings_seat: *XkbBindingsSeat,
    client: *wl.Client,
    version: u32,
    id: u32,
) void {
    assert(bindings_seat.object == null);
    bindings_seat.object = river.XkbBindingsSeatV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    bindings_seat.object.?.setHandler(*XkbBindingsSeat, handleRequest, handleDestroy, bindings_seat);
}

pub fn makeInert(bindings_seat: *XkbBindingsSeat) void {
    if (bindings_seat.object) |object| {
        object.setHandler(?*anyopaque, handleRequestInert, null, null);
        bindings_seat.object = null;
    }
}

fn handleRequestInert(
    object: *river.XkbBindingsSeatV1,
    request: river.XkbBindingsSeatV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) object.destroy();
}

fn handleDestroy(_: *river.XkbBindingsSeatV1, bindings_seat: *XkbBindingsSeat) void {
    bindings_seat.object = null;
}

fn handleRequest(
    object: *river.XkbBindingsSeatV1,
    request: river.XkbBindingsSeatV1.Request,
    bindings_seat: *XkbBindingsSeat,
) void {
    assert(bindings_seat.object == object);
    switch (request) {
        .destroy => object.destroy(),
        .ensure_next_key_eaten => {
            if (!server.wm.ensureWindowing()) return;
            bindings_seat.requested.next_key_change = .ensure_eaten;
        },
        .cancel_ensure_next_key_eaten => {
            if (!server.wm.ensureWindowing()) return;
            bindings_seat.requested.next_key_change = .cancel_ensure_eaten;
        },
    }
}

pub fn manageStart(bindings_seat: *XkbBindingsSeat) void {
    if (bindings_seat.scheduled.ate_unbound_key) {
        if (bindings_seat.object) |object| {
            if (object.getVersion() >= 2) {
                object.sendAteUnboundKey();
            }
        }
        bindings_seat.scheduled.ate_unbound_key = false;
    }
}

pub fn manageFinish(bindings_seat: *XkbBindingsSeat) void {
    switch (bindings_seat.requested.next_key_change) {
        .none => {},
        .ensure_eaten => bindings_seat.ensure_next_key_eaten = true,
        .cancel_ensure_eaten => bindings_seat.ensure_next_key_eaten = false,
    }
    bindings_seat.requested.next_key_change = .none;
}
