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

    const rule_names = xkb.RuleNames{
        .layout = result.args[0],
        // TODO(zig) these should eventually coerce without this hack.
        .rules = if (result.flags.rules) |s| s else null,
        .model = if (result.flags.model) |s| s else null,
        .variant = if (result.flags.variant) |s| s else null,
        .options = if (result.flags.options) |s| s else null,
    };

    const new_keymap = xkb.Keymap.newFromNames(
        server.config.xkb_context,
        &rule_names,
        .no_flags,
    ) orelse return error.InvalidValue;
    defer new_keymap.unref();

    applyLayout(new_keymap);
}

pub fn keyboardLayoutFile(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const file = std.fs.cwd().openFile(args[1], .{}) catch return error.CannotReadFile;
    defer file.close();

    // 1 GiB is arbitrarily chosen as an exceedingly large but not infinite upper bound.
    const file_bytes = file.readToEndAlloc(util.gpa, 1024 * 1024 * 1024) catch |err| {
        switch (err) {
            error.FileTooBig, error.OutOfMemory => return error.OutOfMemory,
            else => return error.CannotReadFile,
        }
    };
    defer util.gpa.free(file_bytes);

    const new_keymap = xkb.Keymap.newFromBuffer(
        server.config.xkb_context,
        file_bytes.ptr,
        file_bytes.len,
        .text_v1,
        .no_flags,
    ) orelse return error.CannotParseFile;
    defer new_keymap.unref();

    applyLayout(new_keymap);
}

fn applyLayout(new_keymap: *xkb.Keymap) void {
    server.config.keymap.unref();
    server.config.keymap = new_keymap.ref();

    var it = server.input_manager.devices.iterator(.forward);
    while (it.next()) |device| {
        if (device.wlr_device.type != .keyboard) continue;
        const wlr_keyboard = device.wlr_device.toKeyboard();
        // wlroots will log an error if this fails and there's unfortunately
        // nothing we can really do in the case of failure.
        _ = wlr_keyboard.setKeymap(new_keymap);

        device.notifyKbdLayoutChanged();
    }
}
