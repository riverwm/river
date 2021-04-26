const Option = @import("deps/zig-shellcomplete/Option.zig");

pub const river_completion = &[_]Option{
    .{
        .name = "-c",
        .description = "Override init command",
        .modifier = .unpredictable,
    },
    .{
        .name = "-l",
        .description = "Set log level",
        .modifier = .{
            .list = &[_]Option.Modifier{
                .{ .name = "0", .description = "emerg" },
                .{ .name = "1", .description = "alert" },
                .{ .name = "2", .description = "crit" },
                .{ .name = "3", .description = "err" },
                .{ .name = "4", .description = "warn" },
                .{ .name = "5", .description = "notice" },
                .{ .name = "6", .description = "info" },
                .{ .name = "7", .description = "debug" },
            },
        },
    },
};
