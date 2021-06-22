// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

pub fn floatFilterAdd(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    try modifyFilter(allocator, &server.config.float_filter, args, .add);
}

pub fn floatFilterRemove(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    try modifyFilter(allocator, &server.config.float_filter, args, .remove);
}

pub fn csdFilterAdd(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    try modifyFilter(allocator, &server.config.csd_filter, args, .add);
    csdFilterUpdateViews(args[1], .add);
}

pub fn csdFilterRemove(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    try modifyFilter(allocator, &server.config.csd_filter, args, .remove);
    csdFilterUpdateViews(args[1], .remove);
}

fn modifyFilter(
    allocator: *std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    args: []const []const u8,
    operation: enum { add, remove },
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;
    for (list.items) |*filter, i| {
        if (std.mem.eql(u8, filter.*, args[1])) {
            if (operation == .remove) {
                allocator.free(list.orderedRemove(i));
            }
            return;
        }
    }
    if (operation == .add) {
        try list.ensureUnusedCapacity(1);
        list.appendAssumeCapacity(try std.mem.dupe(allocator, u8, args[1]));
    }
}

fn csdFilterUpdateViews(app_id: []const u8, operation: enum { add, remove }) void {
    // There is no link between Decoration and View, so we need to iterate over
    // both separately. Note that we do not need to arrange the outputs here; If
    // the clients decoration mode changes, it will receive a configure event.
    var decoration_it = server.decoration_manager.decorations.first;
    while (decoration_it) |decoration_node| : (decoration_it = decoration_node.next) {
        const xdg_toplevel_decoration = decoration_node.data.xdg_toplevel_decoration;
        if (std.mem.eql(
            u8,
            std.mem.span(xdg_toplevel_decoration.surface.role_data.toplevel.app_id orelse return),
            app_id,
        )) {
            _ = xdg_toplevel_decoration.setMode(switch (operation) {
                .add => .client_side,
                .remove => .server_side,
            });
        }
    }

    var output_it = server.root.outputs.first;
    while (output_it) |output_node| : (output_it = output_node.next) {
        var view_it = output_node.data.views.first;
        while (view_it) |view_node| : (view_it = view_node.next) {
            // CSD mode is not supported for XWayland views.
            if (view_node.view.impl == .xwayland_view) continue;

            const view_app_id = std.mem.span(view_node.view.getAppId() orelse continue);
            if (std.mem.eql(u8, app_id, view_app_id)) {
                const toplevel = view_node.view.impl.xdg_toplevel.xdg_surface.role_data.toplevel;
                switch (operation) {
                    .add => {
                        view_node.view.draw_borders = false;
                        _ = toplevel.setTiled(.{ .top = false, .bottom = false, .left = false, .right = false });
                    },
                    .remove => {
                        view_node.view.draw_borders = true;
                        _ = toplevel.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
                    },
                }
            }
        }
    }
}
