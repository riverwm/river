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
const RuleList = @import("../RuleList.zig");
const Seat = @import("../Seat.zig");
const View = @import("../View.zig");

const Action = enum {
    float,
    @"no-float",
    ssd,
    csd,
};

pub fn ruleAdd(_: *Seat, args: []const [:0]const u8, _: *?[]const u8) Error!void {
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
                .value = (action == .float),
            });
        },
        .ssd, .csd => {
            server.config.ssd_rules.del(.{
                .app_id_glob = app_id_glob,
                .title_glob = title_glob,
                .value = (action == .ssd),
            });
            apply_ssd_rules();
            server.root.applyPending();
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

    const list = std.meta.stringToEnum(enum { float, ssd }, args[1]) orelse return Error.UnknownOption;

    const rules = switch (list) {
        .float => server.config.float_rules.rules.items,
        .ssd => server.config.ssd_rules.rules.items,
    };

    var action_column_max = "action".len;
    var app_id_column_max = "app-id".len;
    for (rules) |rule| {
        const action = switch (list) {
            .float => if (rule.value) "float" else "no-float",
            .ssd => if (rule.value) "ssd" else "csd",
        };
        action_column_max = @max(action_column_max, action.len);
        app_id_column_max = @max(app_id_column_max, rule.app_id_glob.len);
    }
    action_column_max += 2;
    app_id_column_max += 2;

    var buffer = std.ArrayList(u8).init(util.gpa);
    const writer = buffer.writer();

    try fmt.formatBuf("action", .{ .width = action_column_max, .alignment = .Left }, writer);
    try fmt.formatBuf("app-id", .{ .width = app_id_column_max, .alignment = .Left }, writer);
    try writer.writeAll("title\n");

    for (rules) |rule| {
        const action = switch (list) {
            .float => if (rule.value) "float" else "no-float",
            .ssd => if (rule.value) "ssd" else "csd",
        };
        try fmt.formatBuf(action, .{ .width = action_column_max, .alignment = .Left }, writer);
        try fmt.formatBuf(rule.app_id_glob, .{ .width = app_id_column_max, .alignment = .Left }, writer);
        try writer.print("{s}\n", .{rule.title_glob});
    }

    out.* = buffer.toOwnedSlice();
}
