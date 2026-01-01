// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const LibinputConfig = @This();

const std = @import("std");
const assert = std.debug.assert;
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;

const c = @import("c.zig").c;
const server = &@import("main.zig").server;

const LibinputAccelConfig = @import("LibinputAccelConfig.zig");
const LibinputDevice = @import("LibinputDevice.zig");

const log = std.log.scoped(.input);

global: *wl.Global,
objects: wl.list.Head(river.LibinputConfigV1, null),
devices: wl.list.Head(LibinputDevice, .link),

server_destroy: wl.Listener(*wl.Server) = .init(handleServerDestroy),

pub fn init(config: *LibinputConfig) !void {
    config.* = .{
        .global = try wl.Global.create(server.wl_server, river.LibinputConfigV1, 1, *LibinputConfig, config, bind),
        .objects = undefined,
        .devices = undefined,
    };
    config.objects.init();
    config.devices.init();
    server.wl_server.addDestroyListener(&config.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const config: *LibinputConfig = @fieldParentPtr("server_destroy", listener);

    config.global.destroy();
}

fn bind(client: *wl.Client, config: *LibinputConfig, version: u32, id: u32) void {
    const object = river.LibinputConfigV1.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    object.setHandler(*LibinputConfig, handleRequest, handleDestroy, config);
    config.objects.append(object);
    {
        var it = config.devices.iterator(.forward);
        while (it.next()) |device| device.createObject(object);
    }
}

fn handleRequestInert(
    object: *river.LibinputConfigV1,
    request: river.LibinputConfigV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) object.destroy();
}

fn handleDestroy(object: *river.LibinputConfigV1, _: *LibinputConfig) void {
    object.getLink().remove();
}

fn handleRequest(
    object: *river.LibinputConfigV1,
    request: river.LibinputConfigV1.Request,
    _: *LibinputConfig,
) void {
    switch (request) {
        .stop => {
            object.getLink().remove();
            object.sendFinished();
            object.setHandler(?*anyopaque, handleRequestInert, null, null);
        },
        .destroy => {
            object.postError(.invalid_destroy, "destroy before finished event sent");
        },
        .create_accel_config => |args| {
            const profile: c.enum_libinput_config_accel_profile = switch (args.profile) {
                .none => c.LIBINPUT_CONFIG_ACCEL_PROFILE_NONE,
                .flat => c.LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT,
                .adaptive => c.LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE,
                .custom => c.LIBINPUT_CONFIG_ACCEL_PROFILE_CUSTOM,
                _ => {
                    object.postError(.invalid_arg, "invalid accel_profile enum value");
                    return;
                },
            };
            LibinputAccelConfig.create(
                object.getClient(),
                object.getVersion(),
                args.id,
                profile,
            ) catch {
                log.err("out of memory", .{});
                object.postNoMemory();
                return;
            };
        },
    }
}
