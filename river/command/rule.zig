// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2023 The River Developers
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
const fmt = std.fmt;

const globber = @import("globber");
const flags = @import("flags");

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");
const View = @import("../View.zig");

const Action = enum {
    float,
    @"no-float",
    ssd,
    csd,
    tags,
    output,
    position,
    dimensions,
    fullscreen,
    @"no-fullscreen",
};

pub fn ruleAdd(_: *Seat, args: []const [:0]const u8, _: *?[]const u8) Error!void {
    const result = flags.parser([:0]const u8, &.{
        .{ .name = "app-id", .kind = .arg },
        .{ .name = "title", .kind = .arg },
    }).parse(args[1..]) catch {
        return error.InvalidValue;
    };

    if (result.args.len < 1) return Error.NotEnoughArguments;

    const action = std.meta.stringToEnum(Action, result.args[0]) orelse return Error.UnknownOption;

    const positional_arguments_count: u8 = switch (action) {
        .float, .@"no-float", .ssd, .csd, .fullscreen, .@"no-fullscreen" => 1,
        .tags, .output => 2,
        .position, .dimensions => 3,
    };
    if (result.args.len > positional_arguments_count) return Error.TooManyArguments;
    if (result.args.len < positional_arguments_count) return Error.NotEnoughArguments;

    const app_id_glob = result.flags.@"app-id" orelse "*";
    const title_glob = result.flags.title orelse "*";

    try globber.validate(app_id_glob);
    try globber.validate(title_glob);

    switch (action) {
        .float, .@"no-float" => {
            try server.config.rules.float.add(.{
                .app_id_glob = app_id_glob,
                .title_glob = title_glob,
                .value = (action == .float),
            });
        },
        .ssd, .csd => {
            try server.config.rules.ssd.add(.{
                .app_id_glob = app_id_glob,
                .title_glob = title_glob,
                .value = (action == .ssd),
            });
            apply_ssd_rules();
            server.root.applyPending();
        },
        .tags => {
            const tags = try fmt.parseInt(u32, result.args[1], 10);
            try server.config.rules.tags.add(.{
                .app_id_glob = app_id_glob,
                .title_glob = title_glob,
                .value = tags,
            });
        },
        .output => {
            const output_name = try util.gpa.dupe(u8, result.args[1]);
            errdefer util.gpa.free(output_name);
            try server.config.rules.output.add(.{
                .app_id_glob = app_id_glob,
                .title_glob = title_glob,
                .value = output_name,
            });
        },
        .position => {
            const x = try fmt.parseInt(u31, result.args[1], 10);
            const y = try fmt.parseInt(u31, result.args[2], 10);
            try server.config.rules.position.add(.{
                .app_id_glob = app_id_glob,
                .title_glob = title_glob,
                .value = .{
                    .x = x,
                    .y = y,
                },
            });
        },
        .dimensions => {
            const width = try fmt.parseInt(u31, result.args[1], 10);
            const height = try fmt.parseInt(u31, result.args[2], 10);
            try server.config.rules.dimensions.add(.{
                .app_id_glob = app_id_glob,
                .title_glob = title_glob,
                .value = .{
                    .width = width,
                    .height = height,
                },
            });
        },
        .fullscreen, .@"no-fullscreen" => {
            try server.config.rules.fullscreen.add(.{
                .app_id_glob = app_id_glob,
                .title_glob = title_glob,
                .value = (action == .fullscreen),
            });
        },
    }
}

pub fn ruleDel(_: *Seat, args: []const [:0]const u8, _: *?[]const u8) Error!void {
    const result = flags.parser([:0]const u8, &.{
        .{ .name = "app-id", .kind = .arg },
        .{ .name = "title", .kind = .arg },
    }).parse(args[1..]) catch {
        return error.InvalidValue;
    };

    if (result.args.len > 1) return Error.TooManyArguments;
    if (result.args.len < 1) return Error.NotEnoughArguments;

    const action = std.meta.stringToEnum(Action, result.args[0]) orelse return Error.UnknownOption;

    const rule = .{
        .app_id_glob = result.flags.@"app-id" orelse "*",
        .title_glob = result.flags.title orelse "*",
    };
    switch (action) {
        .float, .@"no-float" => {
            _ = server.config.rules.float.del(rule);
        },
        .ssd, .csd => {
            _ = server.config.rules.ssd.del(rule);
            apply_ssd_rules();
            server.root.applyPending();
        },
        .tags => {
            _ = server.config.rules.tags.del(rule);
        },
        .output => {
            if (server.config.rules.output.del(rule)) |output_rule| {
                util.gpa.free(output_rule);
            }
        },
        .position => {
            _ = server.config.rules.position.del(rule);
        },
        .dimensions => {
            _ = server.config.rules.dimensions.del(rule);
        },
        .fullscreen, .@"no-fullscreen" => {
            _ = server.config.rules.fullscreen.del(rule);
        },
    }
}

fn apply_ssd_rules() void {
    var it = server.root.views.iterator(.forward);
    while (it.next()) |view| {
        if (view.destroying) continue;

        if (server.config.rules.ssd.match(view)) |ssd| {
            view.pending.ssd = ssd;
        }
    }
}

pub fn listRules(_: *Seat, args: []const [:0]const u8, out: *?[]const u8) Error!void {
    if (args.len < 2) return error.NotEnoughArguments;
    if (args.len > 2) return error.TooManyArguments;

    const rule_list = std.meta.stringToEnum(enum {
        float,
        ssd,
        tags,
        output,
        position,
        dimensions,
        fullscreen,
    }, args[1]) orelse return Error.UnknownOption;
    const max_glob_len = switch (rule_list) {
        inline else => |list| @field(server.config.rules, @tagName(list)).getMaxGlobLen(),
    };
    const app_id_column_max = 2 + @max("app-id".len, max_glob_len.app_id);
    const title_column_max = 2 + @max("title".len, max_glob_len.title);

    var buffer = std.ArrayList(u8).init(util.gpa);
    const writer = buffer.writer();

    try fmt.formatBuf("title", .{ .width = title_column_max, .alignment = .left }, writer);
    try fmt.formatBuf("app-id", .{ .width = app_id_column_max, .alignment = .left }, writer);
    try writer.writeAll("action\n");

    switch (rule_list) {
        inline .float, .ssd, .output, .fullscreen => |list| {
            const rules = switch (list) {
                .float => server.config.rules.float.rules.items,
                .ssd => server.config.rules.ssd.rules.items,
                .output => server.config.rules.output.rules.items,
                .fullscreen => server.config.rules.fullscreen.rules.items,
                else => unreachable,
            };
            for (rules) |rule| {
                try fmt.formatBuf(rule.title_glob, .{ .width = title_column_max, .alignment = .left }, writer);
                try fmt.formatBuf(rule.app_id_glob, .{ .width = app_id_column_max, .alignment = .left }, writer);
                try writer.print("{s}\n", .{switch (list) {
                    .float => if (rule.value) "float" else "no-float",
                    .ssd => if (rule.value) "ssd" else "csd",
                    .output => rule.value,
                    .fullscreen => if (rule.value) "fullscreen" else "no-fullscreen",
                    else => unreachable,
                }});
            }
        },
        .tags => {
            for (server.config.rules.tags.rules.items) |rule| {
                try fmt.formatBuf(rule.title_glob, .{ .width = title_column_max, .alignment = .left }, writer);
                try fmt.formatBuf(rule.app_id_glob, .{ .width = app_id_column_max, .alignment = .left }, writer);
                try writer.print("{b}\n", .{rule.value});
            }
        },
        .position => {
            for (server.config.rules.position.rules.items) |rule| {
                try fmt.formatBuf(rule.title_glob, .{ .width = title_column_max, .alignment = .left }, writer);
                try fmt.formatBuf(rule.app_id_glob, .{ .width = app_id_column_max, .alignment = .left }, writer);
                try writer.print("{d},{d}\n", .{ rule.value.x, rule.value.y });
            }
        },
        .dimensions => {
            for (server.config.rules.dimensions.rules.items) |rule| {
                try fmt.formatBuf(rule.title_glob, .{ .width = title_column_max, .alignment = .left }, writer);
                try fmt.formatBuf(rule.app_id_glob, .{ .width = app_id_column_max, .alignment = .left }, writer);
                try writer.print("{d}x{d}\n", .{ rule.value.width, rule.value.height });
            }
        },
    }

    out.* = try buffer.toOwnedSlice();
}
