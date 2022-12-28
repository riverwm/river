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
const flags = @import("flags");

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

pub fn keyboardLayout(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    const result = flags.parser([:0]const u8, &.{
        .{ .name = "rules", .kind = .arg },
        .{ .name = "model", .kind = .arg },
        .{ .name = "variant", .kind = .arg },
        .{ .name = "options", .kind = .arg },
    }).parse(args[1..]) catch {
        return error.InvalidValue;
    };
    if (result.args.len < 1) return Error.NotEnoughArguments;
    if (result.args.len > 1) return Error.TooManyArguments;

    const new_layout = xkb.RuleNames{
        .layout = try util.gpa.dupeZ(u8, result.args[0]),
        .rules = if (result.flags.rules) |s| try util.gpa.dupeZ(u8, s) else null,
        .model = if (result.flags.model) |s| try util.gpa.dupeZ(u8, s) else null,
        .variant = if (result.flags.variant) |s| try util.gpa.dupeZ(u8, s) else null,
        .options = if (result.flags.options) |s| try util.gpa.dupeZ(u8, s) else null,
    };
    errdefer util.free_xkb_rule_names(new_layout);

    const context = xkb.Context.new(.no_flags) orelse return error.OutOfMemory;
    defer context.unref();

    const keymap = xkb.Keymap.newFromNames(context, &new_layout, .no_flags) orelse return error.InvalidValue;
    defer keymap.unref();

    // Wait until after successfully creating the keymap to save the new layout options.
    // Otherwise we may store invalid layout options which could cause keyboards to become
    // unusable.
    if (server.config.keyboard_layout) |old_layout| util.free_xkb_rule_names(old_layout);
    server.config.keyboard_layout = new_layout;

    var it = server.input_manager.devices.iterator(.forward);
    while (it.next()) |device| {
        if (device.wlr_device.type != .keyboard) continue;
        const wlr_keyboard = device.wlr_device.toKeyboard();
        if (!wlr_keyboard.setKeymap(keymap)) return error.OutOfMemory;
    }
}
