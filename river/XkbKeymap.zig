// SPDX-FileCopyrightText: © 2026 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const XkbKeymap = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const log = std.log.scoped(.input);

object: *river.XkbKeymapV1,
xkb_keymap: *xkb.Keymap,

/// XkbConfig.keymaps
link: wl.list.Link,

pub fn create(
    client: *wl.Client,
    version: u32,
    id: u32,
    xkb_keymap: *xkb.Keymap,
) !void {
    const keymap = try util.gpa.create(XkbKeymap);
    errdefer util.gpa.destroy(keymap);

    const object = try river.XkbKeymapV1.create(client, version, id);
    errdefer comptime unreachable;

    keymap.* = .{
        .object = object,
        .xkb_keymap = xkb_keymap.ref(),
        .link = undefined,
    };
    server.xkb_config.keymaps.append(keymap);

    object.setHandler(*XkbKeymap, handleRequest, handleDestroy, keymap);
    object.sendSuccess();
}

pub fn createFailed(client: *wl.Client, version: u32, id: u32, error_msg: [*:0]const u8) !void {
    const object = try river.XkbKeymapV1.create(client, version, id);
    errdefer comptime unreachable;
    object.setHandler(?*anyopaque, handleRequestInert, null, null);
    object.sendFailure(error_msg);
}

fn handleRequestInert(
    object: *river.XkbKeymapV1,
    request: river.XkbKeymapV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => object.destroy(),
    }
}

fn handleDestroy(_: *river.XkbKeymapV1, keymap: *XkbKeymap) void {
    keymap.xkb_keymap.unref();
    keymap.link.remove();
    util.gpa.destroy(keymap);
}

fn handleRequest(
    object: *river.XkbKeymapV1,
    request: river.XkbKeymapV1.Request,
    keymap: *XkbKeymap,
) void {
    assert(keymap.object == object);
    switch (request) {
        .destroy => object.destroy(),
    }
}
