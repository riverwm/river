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

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const View = @import("../View.zig");
const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

const FilterKind = enum {
    @"app-id",
    title,
};

pub fn floatFilterAdd(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 3) return Error.TooManyArguments;

    const kind = std.meta.stringToEnum(FilterKind, args[1]) orelse return Error.UnknownOption;
    const map = switch (kind) {
        .@"app-id" => &server.config.float_filter_app_ids,
        .title => &server.config.float_filter_titles,
    };

    const key = args[2];
    const gop = try map.getOrPut(util.gpa, key);
    if (gop.found_existing) return;
    errdefer assert(map.remove(key));
    gop.key_ptr.* = try util.gpa.dupe(u8, key);
}

pub fn floatFilterRemove(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 3) return Error.TooManyArguments;

    const kind = std.meta.stringToEnum(FilterKind, args[1]) orelse return Error.UnknownOption;
    const map = switch (kind) {
        .@"app-id" => &server.config.float_filter_app_ids,
        .title => &server.config.float_filter_titles,
    };

    const key = args[2];
    if (map.fetchRemove(key)) |kv| util.gpa.free(kv.key);
}

pub fn csdFilterAdd(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 3) return Error.TooManyArguments;

    const kind = std.meta.stringToEnum(FilterKind, args[1]) orelse return Error.UnknownOption;
    const map = switch (kind) {
        .@"app-id" => &server.config.csd_filter_app_ids,
        .title => &server.config.csd_filter_titles,
    };

    const key = args[2];
    const gop = try map.getOrPut(util.gpa, key);
    if (gop.found_existing) return;
    errdefer assert(map.remove(key));
    gop.key_ptr.* = try util.gpa.dupe(u8, key);

    csdFilterUpdateViews(kind, key, .add);
    server.root.applyPending();
}

pub fn csdFilterRemove(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 3) return Error.TooManyArguments;

    const kind = std.meta.stringToEnum(FilterKind, args[1]) orelse return Error.UnknownOption;
    const map = switch (kind) {
        .@"app-id" => &server.config.csd_filter_app_ids,
        .title => &server.config.csd_filter_titles,
    };

    const key = args[2];
    if (map.fetchRemove(key)) |kv| {
        util.gpa.free(kv.key);
        csdFilterUpdateViews(kind, key, .remove);
        server.root.applyPending();
    }
}

fn csdFilterUpdateViews(kind: FilterKind, pattern: []const u8, operation: enum { add, remove }) void {
    var it = server.root.views.iterator(.forward);
    while (it.next()) |view| {
        if (view.impl == .xdg_toplevel) {
            if (view.impl.xdg_toplevel.decoration) |decoration| {
                if (viewMatchesPattern(kind, pattern, view)) {
                    switch (operation) {
                        .add => {
                            _ = decoration.wlr_decoration.setMode(.client_side);
                            view.pending.borders = false;
                        },
                        .remove => {
                            _ = decoration.wlr_decoration.setMode(.server_side);
                            view.pending.borders = true;
                        },
                    }
                }
            }
        }
    }
}

fn viewMatchesPattern(kind: FilterKind, pattern: []const u8, view: *View) bool {
    const p = switch (kind) {
        .@"app-id" => mem.span(view.getAppId()),
        .title => mem.span(view.getTitle()),
    } orelse return false;

    return mem.eql(u8, pattern, p);
}
