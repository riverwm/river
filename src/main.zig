const std = @import("std");
const c = @import("c.zig");

const Server = @import("server.zig").Server;

pub fn main() !void {
    std.debug.warn("Starting up.\n", .{});

    c.wlr_log_init(c.enum_wlr_log_importance.WLR_DEBUG, null);

    var server: Server = undefined;
    try server.init(std.heap.c_allocator);
    defer server.destroy();

    try server.start();

    server.run();
}
