// SPDX-FileCopyrightText: © 2026 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const XkbConfig = @This();

const std = @import("std");
const assert = std.debug.assert;
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;
const xkb = @import("xkbcommon");

const server = &@import("main.zig").server;

const XkbKeymap = @import("XkbKeymap.zig");
const XkbKeyboard = @import("XkbKeyboard.zig");

const log = std.log.scoped(.input);

global: *wl.Global,
objects: wl.list.Head(river.XkbConfigV1, null),
keymaps: wl.list.Head(XkbKeymap, .link),
keyboards: wl.list.Head(XkbKeyboard, .link),

context: *xkb.Context,
default_keymap: *xkb.Keymap,

server_destroy: wl.Listener(*wl.Server) = .init(handleServerDestroy),

pub fn init(config: *XkbConfig) !void {
    const context = xkb.Context.new(.no_flags) orelse return error.XkbContextFailed;
    defer context.unref();

    // Passing null here indicates that defaults from libxkbcommon and
    // its XKB_DEFAULT_LAYOUT, XKB_DEFAULT_OPTIONS, etc. should be used.
    const default_keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.XkbKeymapFailed;
    defer default_keymap.unref();

    config.* = .{
        .global = try wl.Global.create(server.wl_server, river.XkbConfigV1, 1, *XkbConfig, config, bind),
        .context = context.ref(),
        .default_keymap = default_keymap.ref(),
        .objects = undefined,
        .keymaps = undefined,
        .keyboards = undefined,
    };
    errdefer comptime unreachable;
    config.objects.init();
    config.keymaps.init();
    config.keyboards.init();

    server.wl_server.addDestroyListener(&config.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const config: *XkbConfig = @fieldParentPtr("server_destroy", listener);

    config.global.destroy();
    config.context.unref();
    config.default_keymap.unref();
}

fn bind(client: *wl.Client, config: *XkbConfig, version: u32, id: u32) void {
    const object = river.XkbConfigV1.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    object.setHandler(*XkbConfig, handleRequest, handleDestroy, config);
    config.objects.append(object);
    {
        var it = config.keyboards.iterator(.forward);
        while (it.next()) |device| device.createObject(object);
    }
}

fn handleRequestInert(
    object: *river.XkbConfigV1,
    request: river.XkbConfigV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) object.destroy();
}

fn handleDestroy(object: *river.XkbConfigV1, _: *XkbConfig) void {
    object.getLink().remove();
}

fn handleRequest(
    object: *river.XkbConfigV1,
    request: river.XkbConfigV1.Request,
    _: *XkbConfig,
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
        .create_keymap => |args| {
            const format: xkb.Keymap.Format = switch (args.format) {
                .text_v1 => .text_v1,
                .text_v2 => .text_v2,
                _ => {
                    object.postError(.invalid_format, "invalid format enum value");
                    return;
                },
            };
            createKeymap(object, args.id, format, args.fd) catch |err| switch (err) {
                error.OutOfMemory, error.ResourceCreateFailed => {
                    log.err("out of memory", .{});
                    object.postNoMemory();
                    return;
                },
            };
        },
    }
}

/// The goal of this function is to handle whatever fd the client has sent us without crashing.
/// The fd may be invalid, impossible to mmap, not contain a valid keymap, etc.
/// This requires us to avoid the syscall wrappers in std.posix which assert on EBADF for example.
fn createKeymap(object: *river.XkbConfigV1, id: u32, format: xkb.Keymap.Format, fd: i32) !void {
    defer _ = std.c.close(fd);

    var stat: std.c.Stat = std.mem.zeroes(std.c.Stat);
    switch (std.posix.errno(std.c.fstat(fd, &stat))) {
        .SUCCESS => {},
        else => |e| {
            log.err("failed to fstat() keymap fd: E{s}", .{@tagName(e)});
            return XkbKeymap.createFailed(object.getClient(), object.getVersion(), id, "failed to fstat() keymap fd");
        },
    }
    // Must be zero terminated
    if (stat.size < 1) {
        log.err("keymap too small", .{});
        return XkbKeymap.createFailed(object.getClient(), object.getVersion(), id, "keymap too small");
    }
    if (stat.size > 1024 * 1024) {
        log.err("keymap too large: {d} bytes", .{stat.size});
        return XkbKeymap.createFailed(object.getClient(), object.getVersion(), id, "keymap too large");
    }
    const keymap_len: usize = @intCast(stat.size - 1);

    const keymap_ptr = std.c.mmap(null, keymap_len, std.c.PROT.READ, .{ .TYPE = .PRIVATE }, fd, 0);
    if (keymap_ptr == std.c.MAP_FAILED) {
        log.err("failed to mmap() keymap fd: {s}", .{@tagName(@as(std.c.E, @enumFromInt(std.c._errno().*)))});
        return XkbKeymap.createFailed(object.getClient(), object.getVersion(), id, "failed to mmap() keymap fd");
    }
    defer _ = std.c.munmap(@alignCast(keymap_ptr), keymap_len);

    const keymap = xkb.Keymap.newFromBuffer(
        server.xkb_config.context,
        @ptrCast(keymap_ptr),
        keymap_len,
        format,
        .no_flags,
    ) orelse {
        log.err("failed to parse xkb keymap", .{});
        return XkbKeymap.createFailed(object.getClient(), object.getVersion(), id, "failed to parse xkb keymap");
    };
    defer keymap.unref();

    try XkbKeymap.create(object.getClient(), object.getVersion(), id, keymap);
}
