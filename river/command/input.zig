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
const sort = std.sort;

const globber = @import("globber");

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");
const InputConfig = @import("../InputConfig.zig");

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
            if (globber.match(device.identifier, input_config.glob)) {
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

    try globber.validate(args[1]);

    // Try to find an existing InputConfig with matching glob pattern, or create
    // a new one if none was found.
    for (server.input_manager.configs.items) |*input_config| {
        if (mem.eql(u8, input_config.glob, args[1])) {
            try input_config.parse(args[2], args[3]);
        }
    } else {
        var input_config: InputConfig = .{
            .glob = try util.gpa.dupe(u8, args[1]),
        };
        errdefer util.gpa.free(input_config.glob);

        try server.input_manager.configs.ensureUnusedCapacity(1);

        try input_config.parse(args[2], args[3]);

        server.input_manager.configs.appendAssumeCapacity(input_config);
    }

    // Sort input configs from most general to least general
    sort.insertion(InputConfig, server.input_manager.configs.items, {}, lessThan);

    // We need to update all input device matching the glob. The user may
    // add an input configuration at an arbitrary position in the generality
    // ordered list, so the simplest way to ensure the device is configured
    // correctly is to apply all input configurations again, in order.
    server.input_manager.reconfigureDevices();
}

fn lessThan(_: void, a: InputConfig, b: InputConfig) bool {
    return globber.order(a.glob, b.glob) == .gt;
}
