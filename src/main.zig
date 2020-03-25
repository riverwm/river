const std = @import("std");
const c = @import("c.zig").c;

const Server = @import("server.zig").Server;

pub fn main() !void {
    std.debug.warn("Starting up.\n", .{});

    c.wlr_log_init(c.enum_wlr_log_importance.WLR_DEBUG, null);

    var server: Server = undefined;
    try server.init(std.heap.c_allocator);
    defer server.destroy();

    try server.start();

    // Spawn an instance of alacritty
    // const argv = [_][]const u8{ "/bin/sh", "-c", "WAYLAND_DEBUG=1 alacritty" };
    const argv = [_][]const u8{ "/bin/sh", "-c", "alacritty" };
    const child = try std.ChildProcess.init(&argv, std.heap.c_allocator);
    try std.ChildProcess.spawn(child);

    server.run();
}
