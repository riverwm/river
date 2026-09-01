// SPDX-FileCopyrightText: © 2026 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const TransientSeatManager = @This();

const std = @import("std");
const assert = std.debug.assert;
const fmt = std.fmt;
const math = std.math;
const mem = std.mem;
const wl = @import("wayland").server.wl;
const ext = @import("wayland").server.ext;

const server = &@import("main.zig").server;

const Seat = @import("Seat.zig");

const log = std.log.scoped(.input);

global: *wl.Global,
objects: wl.list.Head(ext.TransientSeatManagerV1, null),
seats: wl.list.Head(ext.TransientSeatV1, null),
suffix: u32 = 0,

/// This protocol is implemented directly in river rather than using the wlroots helper
/// since the the wlroots implementation directly calls wlr_seat_destroy() when the
/// client ext_transient seat_v1 object is destroyed. River does not want to actually
/// destroy the wlr_seat until the the next manage sequence is completed.
pub fn init(manager: *TransientSeatManager) !void {
    manager.* = .{
        .global = try wl.Global.create(server.wl_server, ext.TransientSeatManagerV1, 1, *TransientSeatManager, manager, bind),
        .objects = undefined,
        .seats = undefined,
    };
    manager.objects.init();
    manager.seats.init();
}

pub fn deinit(manager: *TransientSeatManager) void {
    assert(manager.objects.empty());
    assert(manager.seats.empty());
}

fn bind(client: *wl.Client, manager: *TransientSeatManager, version: u32, id: u32) void {
    const object = ext.TransientSeatManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    object.setHandler(*TransientSeatManager, handleRequest, handleDestroy, manager);
    manager.objects.append(object);
}

fn handleRequest(object: *ext.TransientSeatManagerV1, req: ext.TransientSeatManagerV1.Request, manager: *TransientSeatManager) void {
    switch (req) {
        .create => |args| {
            const transient = ext.TransientSeatV1.create(object.getClient(), object.getVersion(), args.seat) catch {
                object.postNoMemory();
                log.err("out of memory", .{});
                return;
            };

            // +1 for the sentinel
            var buf: [1 + fmt.count("transient-{}", .{math.maxInt(u32)})]u8 = undefined;
            const name = name: while (true) {
                const name = std.fmt.bufPrintSentinel(&buf, "transient-{}", .{manager.suffix}, 0) catch unreachable;
                manager.suffix +%= 1;

                // If the name is already taken, try the next one.
                // It should be impossible for 2^32 transient seats to exist without the system running out of memory.
                var it = server.input_manager.seats.safeIterator(.forward);
                while (it.next()) |seat| if (mem.orderZ(u8, seat.wlr_seat.name, name) == .eq) continue :name;

                break :name name;
            };

            Seat.create(name, transient) catch |err| switch (err) {
                error.OutOfMemory, error.AddTimerFailed => {
                    object.postNoMemory();
                    log.err("out of memory", .{});
                    return;
                },
            };

            transient.setHandler(?*anyopaque, transientHandleRequest, transientHandleDestroy, null);

            manager.seats.append(transient);
        },
        .destroy => {
            object.destroy();
        },
    }
}

fn handleDestroy(object: *ext.TransientSeatManagerV1, _: *TransientSeatManager) void {
    object.getLink().remove();
}

fn transientHandleRequest(transient: *ext.TransientSeatV1, req: ext.TransientSeatV1.Request, _: ?*anyopaque) void {
    switch (req) {
        .destroy => transient.destroy(),
    }
}

fn transientHandleDestroy(transient: *ext.TransientSeatV1, _: ?*anyopaque) void {
    var it = server.input_manager.seats.safeIterator(.forward);
    while (it.next()) |seat| if (seat.transient == transient) {
        seat.transient = null;
        seat.destroying = true;
        server.wm.dirtyWindowing();
        break;
    };

    transient.getLink().remove();
}
