// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const Config = @This();

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Server = @import("Server.zig");

xkb_context: *xkb.Context,
/// The xkb keymap used for all keyboards
keymap: *xkb.Keymap,

pub fn init() !Config {
    const xkb_context = xkb.Context.new(.no_flags) orelse return error.XkbContextFailed;
    defer xkb_context.unref();

    // Passing null here indicates that defaults from libxkbcommon and
    // its XKB_DEFAULT_LAYOUT, XKB_DEFAULT_OPTIONS, etc. should be used.
    const keymap = xkb.Keymap.newFromNames(xkb_context, null, .no_flags) orelse return error.XkbKeymapFailed;
    defer keymap.unref();

    var config = Config{
        .xkb_context = xkb_context.ref(),
        .keymap = keymap.ref(),
    };
    errdefer config.deinit();

    return config;
}

pub fn deinit(config: *Config) void {
    config.keymap.unref();
    config.xkb_context.unref();
}
