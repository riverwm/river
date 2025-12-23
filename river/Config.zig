// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const Config = @This();

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Server = @import("Server.zig");

/// Color of background in RGBA with premultiplied alpha (alpha should only affect nested sessions)
background_color: [4]f32 = [_]f32{ 0.0, 0.16862745, 0.21176471, 1.0 }, // Solarized base03

/// Keyboard repeat rate in characters per second
repeat_rate: u31 = 25,

/// Keyboard repeat delay in milliseconds
repeat_delay: u31 = 600,

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
