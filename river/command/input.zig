// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 The River Developers
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

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");
const InputConfig = @import("../InputConfig.zig");
const InputManager = @import("../InputManager.zig");

pub fn listInputs(
    _: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len > 1) return error.TooManyArguments;

    var input_list = std.ArrayList(u8).init(util.gpa);
    const writer = input_list.writer();
    var prev = false;

    var it = server.input_manager.devices.iterator(.forward);
    while (it.next()) |device| {
        const configured = for (server.input_manager.configs.items) |*input_config| {
            if (mem.eql(u8, input_config.identifier, device.identifier)) {
                break true;
            }
        } else false;

        if (prev) try input_list.appendSlice("\n");
        prev = true;

        try writer.print("{s}\n\tconfigured: {}\n", .{
            device.identifier,
            configured,
        });
    }

    out.* = try input_list.toOwnedSlice();
}

pub fn listInputConfigs(
    _: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len > 1) return error.TooManyArguments;

    var input_list = std.ArrayList(u8).init(util.gpa);
    const writer = input_list.writer();

    for (server.input_manager.configs.items, 0..) |*input_config, i| {
        if (i > 0) try writer.writeByte('\n');
        try input_config.write(writer);
    }

    out.* = try input_list.toOwnedSlice();
}

pub fn input(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 4) return Error.NotEnoughArguments;
    if (args.len > 4) return Error.TooManyArguments;

    // Try to find an existing InputConfig with matching identifier, or create
    // a new one if none was found.
    const input_config = for (server.input_manager.configs.items) |*input_config| {
        if (mem.eql(u8, input_config.identifier, args[1])) {
            try input_config.parse(args[2], args[3]);
            break input_config;
        }
    } else blk: {
        const identifier_owned = try util.gpa.dupe(u8, args[1]);
        errdefer util.gpa.free(identifier_owned);

        try server.input_manager.configs.ensureUnusedCapacity(1);
        const input_config = server.input_manager.configs.addOneAssumeCapacity();
        errdefer _ = server.input_manager.configs.pop();

        input_config.* = .{
            .identifier = identifier_owned,
        };
        try input_config.parse(args[2], args[3]);

        break :blk input_config;
    };

    // Update matching existing input devices.
    var it = server.input_manager.devices.iterator(.forward);
    while (it.next()) |device| {
        if (mem.eql(u8, device.identifier, args[1])) {
            input_config.apply(device);
            // We don't break here because it is common to have multiple input
            // devices with the same identifier.
        }
    }
}
