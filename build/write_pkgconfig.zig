// SPDX-FileCopyrightText: © 2026 The River Developers
// SPDX-License-Identifier: 0BSD

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.MissingArgument;

    const install_prefix = args[1];
    const full_version = args[2];

    var stdout_buffer: [64]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        \\prefix={s}
        \\datarootdir=${{prefix}}/share
        \\pkgdatadir=${{pc_sysrootdir}}${{datarootdir}}/river-protocols
        \\
        \\Name: river-protocols
        \\URL: https://isaacfreund.com/software/river
        \\Description: Protocol files for river, a non-monolithic Wayland compositor
        \\Version: {s}
    , .{ install_prefix, full_version });

    try stdout.flush();
}
