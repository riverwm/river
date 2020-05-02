// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
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

const c = @import("c.zig");

const Log = @import("log.zig").Log;
const Server = @import("server.zig");

pub fn main() !void {
    Log.init(Log.Debug);
    c.wlr_log_init(.WLR_ERROR, null);

    Log.Info.log("Initializing server", .{});

    var server: Server = undefined;
    try server.init(std.heap.c_allocator);
    defer server.deinit();

    try server.start();

    Log.Info.log("Running server...", .{});

    server.run();

    Log.Info.log("Shutting down server", .{});
}
