// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
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
const wl = @import("wayland").server.wl;
const util = @import("../util.zig");

const server = &@import("../main.zig").server;

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

pub fn outputLayout(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const output = seat.focused_output;
    output.layout_namespace = try util.gpa.dupe(u8, args[1]);
    output.handleLayoutNamespaceChange();
}

pub fn defaultLayout(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    server.config.default_layout_namespace = try util.gpa.dupe(u8, args[1]);
    var it = server.root.all_outputs.first;
    while (it) |node| : (it = node.next) {
        const output = node.data;
        if (output.layout_namespace == null) output.handleLayoutNamespaceChange();
    }
}

const SetType = enum {
    int,
    fixed,
    string,
};

/// riverctl set-layout-value rivertile int main_count 42
/// riverctl set-layout-value rivertile fixed main_factor 42.0
/// riverctl set-layout-value rivertile string main_location top
pub fn setLayoutValue(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 5) return Error.NotEnoughArguments;
    if (args.len > 5) return Error.TooManyArguments;

    const target_namespace = args[1];
    const kind = std.meta.stringToEnum(SetType, args[2]) orelse return Error.InvalidType;

    const output = seat.focused_output;

    var it = output.layouts.first;
    const layout = while (it) |node| : (it = node.next) {
        const layout = &node.data;
        if (mem.eql(u8, layout.namespace, target_namespace)) break layout;
    } else return;

    const null_terminated_name = try util.gpa.dupeZ(u8, args[3]);
    defer util.gpa.free(null_terminated_name);

    switch (kind) {
        .int => {
            const value = try std.fmt.parseInt(i32, args[4], 10);
            layout.layout.sendSetIntValue(null_terminated_name, value);
        },
        .fixed => {
            const value = try std.fmt.parseFloat(f64, args[4]);
            layout.layout.sendSetFixedValue(null_terminated_name, wl.Fixed.fromDouble(value));
        },
        .string => {
            const null_terminated_value = try util.gpa.dupeZ(u8, args[4]);
            defer util.gpa.free(null_terminated_value);
            layout.layout.sendSetStringValue(null_terminated_name, null_terminated_value);
        },
    }

    output.arrangeViews();
}

const ModType = enum {
    int,
    fixed,
};

/// riverctl mode-layout-value rivertile int main_count 42
/// riverctl set-layout-value rivertile fixed main_factor 42.0
pub fn modLayoutValue(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 5) return Error.NotEnoughArguments;
    if (args.len > 5) return Error.TooManyArguments;

    const target_namespace = args[1];
    const kind = std.meta.stringToEnum(ModType, args[2]) orelse return Error.InvalidType;

    const output = seat.focused_output;

    var it = output.layouts.first;
    const layout = while (it) |node| : (it = node.next) {
        const layout = &node.data;
        if (mem.eql(u8, layout.namespace, target_namespace)) break layout;
    } else return;

    const null_terminated_name = try util.gpa.dupeZ(u8, args[3]);
    defer util.gpa.free(null_terminated_name);

    switch (kind) {
        .int => {
            const value = try std.fmt.parseInt(i32, args[4], 10);
            layout.layout.sendModIntValue(null_terminated_name, value);
        },
        .fixed => {
            const value = try std.fmt.parseFloat(f64, args[4]);
            layout.layout.sendModFixedValue(null_terminated_name, wl.Fixed.fromDouble(value));
        },
    }

    output.arrangeViews();
}
