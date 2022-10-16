// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2022 The River Developers
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

const std = @import("std");
const mem = std.mem;

const xkb = @import("xkbcommon");

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

pub fn keyboardLayout(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len % 2 != 0) return Error.InvalidValue;

    // Do not carry over any previous keyboard layout configuration, always
    // start fresh.
    if (server.config.keyboard_layout) |kl| {
        if (kl.rules) |s| util.gpa.free(mem.span(s));
        if (kl.model) |s| util.gpa.free(mem.span(s));
        if (kl.layout) |s| util.gpa.free(mem.span(s));
        if (kl.variant) |s| util.gpa.free(mem.span(s));
        if (kl.options) |s| util.gpa.free(mem.span(s));
    }

    server.config.keyboard_layout = xkb.RuleNames{
        .layout = try util.gpa.dupeZ(u8, args[1]),
        .rules = null,
        .model = null,
        .variant = null,
        .options = null,
    };

    // TODO[zig]: this can be solved more elegantly with an inline for loop, but
    //            on version 0.9.1 that crashes the compiler.
    var i: usize = 2;
    while (i < args.len - 1) : (i += 2) {
        if (mem.eql(u8, args[i], "-variant")) {
            // Do not allow duplicate flags.
            if (server.config.keyboard_layout.?.variant != null) return error.InvalidValue;
            server.config.keyboard_layout.?.variant = try util.gpa.dupeZ(u8, args[i + 1]);
        } else if (mem.eql(u8, args[i], "-model")) {
            if (server.config.keyboard_layout.?.model != null) return error.InvalidValue;
            server.config.keyboard_layout.?.model = try util.gpa.dupeZ(u8, args[i + 1]);
        } else if (mem.eql(u8, args[i], "-options")) {
            if (server.config.keyboard_layout.?.options != null) return error.InvalidValue;
            server.config.keyboard_layout.?.options = try util.gpa.dupeZ(u8, args[i + 1]);
        } else if (mem.eql(u8, args[i], "-rules")) {
            if (server.config.keyboard_layout.?.rules != null) return error.InvalidValue;
            server.config.keyboard_layout.?.rules = try util.gpa.dupeZ(u8, args[i + 1]);
        } else {
            return error.InvalidValue;
        }
    }

    const context = xkb.Context.new(.no_flags) orelse return error.OutOfMemory;
    defer context.unref();

    const keymap = xkb.Keymap.newFromNames(context, &server.config.keyboard_layout.?, .no_flags) orelse return error.InvalidValue;
    defer keymap.unref();

    var it = server.input_manager.devices.iterator(.forward);
    while (it.next()) |device| {
        if (device.wlr_device.type != .keyboard) continue;
        const wlr_keyboard = device.wlr_device.toKeyboard();
        if (!wlr_keyboard.setKeymap(keymap)) return error.OutOfMemory;
    }
}
