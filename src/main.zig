const std = @import("std");
const c = @import("c.zig").c;

pub fn main() !void {
    std.debug.warn("Starting up.\n", .{});

    c.wlr_log_init(c.enum_wlr_log_importance.WLR_DEBUG, null);

    var server = try Server.init(std.heap.c_allocator);
    defer server.deinit();

    try server.start();

    // Spawn an instance of alacritty
    // const argv = [_][]const u8{ "/bin/sh", "-c", "WAYLAND_DEBUG=1 alacritty" };
    const argv = [_][]const u8{ "/bin/sh", "-c", "alacritty" };
    var child = try std.ChildProcess.init(&argv, std.heap.c_allocator);
    try std.ChildProcess.spawn(child);

    server.run();
}
