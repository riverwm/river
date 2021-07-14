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
const assert = std.debug.assert;
const mem = std.mem;

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const View = @import("../View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

pub fn floatFilterAdd(
    allocator: *mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const gop = try server.config.float_filter.getOrPut(util.gpa, args[1]);
    if (gop.found_existing) return;
    errdefer assert(server.config.float_filter.remove(args[1]));
    gop.key_ptr.* = try std.mem.dupe(util.gpa, u8, args[1]);
}

pub fn floatFilterRemove(
    allocator: *mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    if (server.config.float_filter.fetchRemove(args[1])) |kv| util.gpa.free(kv.key);
}

pub fn csdFilterAdd(
    allocator: *mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const gop = try server.config.csd_filter.getOrPut(util.gpa, args[1]);
    if (gop.found_existing) return;
    errdefer assert(server.config.csd_filter.remove(args[1]));
    gop.key_ptr.* = try std.mem.dupe(util.gpa, u8, args[1]);

    csdFilterUpdateViews(args[1], .add);
}

pub fn csdFilterRemove(
    allocator: *mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    if (server.config.csd_filter.fetchRemove(args[1])) |kv| {
        util.gpa.free(kv.key);
        csdFilterUpdateViews(args[1], .remove);
    }
}

fn csdFilterUpdateViews(app_id: []const u8, operation: enum { add, remove }) void {
    var decoration_it = server.decoration_manager.decorations.first;
    while (decoration_it) |decoration_node| : (decoration_it = decoration_node.next) {
        const xdg_toplevel_decoration = decoration_node.data.xdg_toplevel_decoration;
        const view = @intToPtr(*View, xdg_toplevel_decoration.surface.data);
        const view_app_id = mem.span(view.getAppId()) orelse continue;

        if (mem.eql(u8, app_id, view_app_id)) {
            const toplevel = view.impl.xdg_toplevel.xdg_surface.role_data.toplevel;
            switch (operation) {
                .add => {
                    _ = xdg_toplevel_decoration.setMode(.client_side);
                    view.draw_borders = false;
                    _ = toplevel.setTiled(.{ .top = false, .bottom = false, .left = false, .right = false });
                },
                .remove => {
                    _ = xdg_toplevel_decoration.setMode(.server_side);
                    view.draw_borders = true;
                    _ = toplevel.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
                },
            }
        }
    }
}
