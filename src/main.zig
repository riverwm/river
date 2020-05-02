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
