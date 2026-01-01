// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const LibinputAccelConfig = @This();

const std = @import("std");
const assert = std.debug.assert;
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const c = @import("c.zig").c;
const server = &@import("main.zig").server;
const util = @import("util.zig");

const Keyboard = @import("Keyboard.zig");
const Seat = @import("Seat.zig");

const log = std.log.scoped(.input);

object: *river.LibinputAccelConfigV1,
libinput: ?*c.libinput_config_accel,

pub fn create(
    client: *wl.Client,
    version: u32,
    id: u32,
    profile: c.enum_libinput_config_accel_profile,
) !void {
    const accel_config = try util.gpa.create(LibinputAccelConfig);
    errdefer util.gpa.destroy(accel_config);
    const object = try river.LibinputAccelConfigV1.create(client, version, id);
    errdefer comptime unreachable;
    accel_config.* = .{
        .object = object,
        .libinput = c.libinput_config_accel_create(profile),
    };
    object.setHandler(*LibinputAccelConfig, handleRequest, handleDestroy, accel_config);
}

fn handleDestroy(_: *river.LibinputAccelConfigV1, accel_config: *LibinputAccelConfig) void {
    if (accel_config.libinput) |libinput| {
        c.libinput_config_accel_destroy(libinput);
    }
    util.gpa.destroy(accel_config);
}

fn handleRequest(
    object: *river.LibinputAccelConfigV1,
    request: river.LibinputAccelConfigV1.Request,
    accel_config: *LibinputAccelConfig,
) void {
    assert(accel_config.object == object);
    switch (request) {
        .destroy => object.destroy(),
        .set_points => |args| {
            const accel_type: c.enum_libinput_config_accel_type = switch (args.type) {
                .fallback => c.LIBINPUT_ACCEL_TYPE_FALLBACK,
                .motion => c.LIBINPUT_ACCEL_TYPE_MOTION,
                .scroll => c.LIBINPUT_ACCEL_TYPE_SCROLL,
                _ => {
                    object.postError(.invalid_arg, "invalid accel_type enum value");
                    return;
                },
            };
            if (args.step.size != @sizeOf(f64)) {
                object.postError(.invalid_arg, "invalid step argument");
                return;
            }
            const step: f64 = args.step.slice(f64)[0];
            if (args.points.size % @sizeOf(f64) != 0) {
                object.postError(.invalid_arg, "invalid points argument");
                return;
            }
            const points = util.gpa.alloc(f64, @divExact(args.points.size, @sizeOf(f64))) catch {
                log.err("out of memory", .{});
                object.postNoMemory();
                return;
            };
            defer util.gpa.free(points);
            @memcpy(
                @as([]u8, @ptrCast(points)),
                @as([*]u8, @ptrCast(args.points.data))[0..args.points.size],
            );
            const result = river.LibinputResultV1.create(
                object.getClient(),
                object.getVersion(),
                args.result,
            ) catch {
                log.err("out of memory", .{});
                object.postNoMemory();
                return;
            };
            const libinput = accel_config.libinput orelse {
                result.destroySendInvalid();
                return;
            };
            switch (c.libinput_config_accel_set_points(
                libinput,
                accel_type,
                step,
                points.len,
                points.ptr,
            )) {
                c.LIBINPUT_CONFIG_STATUS_SUCCESS => result.destroySendSuccess(),
                c.LIBINPUT_CONFIG_STATUS_UNSUPPORTED => result.destroySendUnsupported(),
                else => result.destroySendInvalid(),
            }
        },
    }
}
