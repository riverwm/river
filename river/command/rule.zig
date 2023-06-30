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
    tag,
};

pub fn ruleAdd(_: *Seat, args: []const [:0]const u8, _: *?[]const u8) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;

    const result = flags.parser([:0]const u8, &.{
        .{ .name = "app-id", .kind = .arg },
        .{ .name = "title", .kind = .arg },
    }).parse(args[2..]) catch {
        return error.InvalidValue;
    };

    const action = std.meta.stringToEnum(Action, args[1]) orelse return Error.UnknownOption;

    const positional_arguments_count: u8 = switch (action) {
        .float, .@"no-float", .ssd, .csd => 0,
        .tag => 1,
    };
    if (result.args.len > positional_arguments_count) return Error.TooManyArguments;
    if (result.args.len < positional_arguments_count) return Error.NotEnoughArguments;

    const app_id_glob = result.flags.@"app-id" orelse "*";
    const title_glob = result.flags.title orelse "*";

    try globber.validate(app_id_glob);
    try globber.validate(title_glob);

    switch (action) {
        .float, .@"no-float" => {
            try server.config.float_rules.add(.{
                .app_id_glob = app_id_glob,
                .title_glob = title_glob,
                .value = (action == .float),
            });
        },
        .ssd, .csd => {
            try server.config.ssd_rules.add(.{
                .app_id_glob = app_id_glob,
                .title_glob = title_glob,
                .value = (action == .ssd),
            });
            apply_ssd_rules();
            server.root.applyPending();
        },
        .tag => {
            const tag = try fmt.parseInt(u32, result.args[0], 10);
            try server.config.tag_rules.add(.{
                .app_id_glob = app_id_glob,
                .title_glob = title_glob,
                .value = tag,
            });
        },
    }
}

pub fn ruleDel(_: *Seat, args: []const [:0]const u8, _: *?[]const u8) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;

    const result = flags.parser([:0]const u8, &.{
        .{ .name = "app-id", .kind = .arg },
        .{ .name = "title", .kind = .arg },
    }).parse(args[2..]) catch {
        return error.InvalidValue;
    };

    if (result.args.len > 0) return Error.TooManyArguments;

    const action = std.meta.stringToEnum(Action, args[1]) orelse return Error.UnknownOption;
    const app_id_glob = result.flags.@"app-id" orelse "*";
    const title_glob = result.flags.title orelse "*";

    switch (action) {
        .float, .@"no-float" => {
            server.config.float_rules.del(.{
                .app_id_glob = app_id_glob,
                .title_glob = title_glob,
            });
        },
        .ssd, .csd => {
            server.config.ssd_rules.del(.{
                .app_id_glob = app_id_glob,
                .title_glob = title_glob,
            });
            apply_ssd_rules();
            server.root.applyPending();
        },
        .tag => {
            server.config.tag_rules.del(.{
                .app_id_glob = app_id_glob,
                .title_glob = title_glob,
            });
        },
    }
}

fn apply_ssd_rules() void {
    var it = server.root.views.iterator(.forward);
    while (it.next()) |view| {
        if (server.config.ssd_rules.match(view)) |ssd| {
            view.pending.ssd = ssd;
        }
    }
}

pub fn listRules(_: *Seat, args: []const [:0]const u8, out: *?[]const u8) Error!void {
    if (args.len < 2) return error.NotEnoughArguments;
    if (args.len > 2) return error.TooManyArguments;

    const list = std.meta.stringToEnum(enum {
        float,
        ssd,
        tag,
    }, args[1]) orelse return Error.UnknownOption;
    const max_glob_len = switch (list) {
        .float => server.config.float_rules.getMaxGlobLen(),
        .ssd => server.config.ssd_rules.getMaxGlobLen(),
        .tag => server.config.tag_rules.getMaxGlobLen(),
    };
    const app_id_column_max = 2 + @max("app-id".len, max_glob_len.app_id);
    const title_column_max = 2 + @max("title".len, max_glob_len.title);

    var buffer = std.ArrayList(u8).init(util.gpa);
    const writer = buffer.writer();

    try fmt.formatBuf("title", .{ .width = title_column_max, .alignment = .Left }, writer);
    try fmt.formatBuf("app-id", .{ .width = app_id_column_max, .alignment = .Left }, writer);
    try writer.writeAll("action\n");

    switch (list) {
        .float, .ssd => {
            const rules = switch (list) {
                .float => server.config.float_rules.rules.items,
                .ssd => server.config.ssd_rules.rules.items,
                else => unreachable,
            };
            for (rules) |rule| {
                try fmt.formatBuf(rule.title_glob, .{ .width = title_column_max, .alignment = .Left }, writer);
                try fmt.formatBuf(rule.app_id_glob, .{ .width = app_id_column_max, .alignment = .Left }, writer);
                try writer.print("{s}\n", .{switch (list) {
                    .float => if (rule.value) "float" else "no-float",
                    .ssd => if (rule.value) "ssd" else "csd",
                    else => unreachable,
                }});
            }
        },
        .tag => {
            const rules = server.config.tag_rules.rules.items;
            for (rules) |rule| {
                try fmt.formatBuf(rule.title_glob, .{ .width = title_column_max, .alignment = .Left }, writer);
                try fmt.formatBuf(rule.app_id_glob, .{ .width = app_id_column_max, .alignment = .Left }, writer);
                try writer.print("{b}\n", .{rule.value});
            }
        },
    }

    out.* = buffer.toOwnedSlice();
}
