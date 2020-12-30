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

const Orientation = enum {
    left,
    right,
    top,
    bottom,
};

/// This is an implementation of the  default "tiled" layout of dwm and the
/// 3 other orientations thereof. This code is written with the left
/// orientation in mind and then the input/output values are adjusted to apply
/// the necessary transformations to derive the other 3.
///
/// With 4 views and one main view, the left layout looks something like this:
///
/// +-----------------------+------------+
/// |                       |            |
/// |                       |            |
/// |                       |            |
/// |                       +------------+
/// |                       |            |
/// |                       |            |
/// |                       |            |
/// |                       +------------+
/// |                       |            |
/// |                       |            |
/// |                       |            |
/// +-----------------------+------------+
pub fn main() !void {
    const args = std.os.argv;
    if (args.len != 7) printUsageAndExit();

    // first arg must be left, right, top, or bottom
    const main_location = std.meta.stringToEnum(Orientation, std.mem.spanZ(args[1])) orelse
        printUsageAndExit();

    // the other 5 are passed by river and described in river-layouts(7)
    const num_views = try std.fmt.parseInt(u32, std.mem.spanZ(args[2]), 10);
    const main_count = try std.fmt.parseInt(u32, std.mem.spanZ(args[3]), 10);
    const main_factor = try std.fmt.parseFloat(f64, std.mem.spanZ(args[4]));

    const width_arg: u32 = switch (main_location) {
        .left, .right => 5,
        .top, .bottom => 6,
    };
    const height_arg: u32 = if (width_arg == 5) 6 else 5;

    const output_width = try std.fmt.parseInt(u32, std.mem.spanZ(args[width_arg]), 10);
    const output_height = try std.fmt.parseInt(u32, std.mem.spanZ(args[height_arg]), 10);

    const secondary_count = if (num_views > main_count) num_views - main_count else 0;

    // to make things pixel-perfect, we make the first main and first secondary
    // view slightly larger if the height is not evenly divisible
    var main_width: u32 = undefined;
    var main_height: u32 = undefined;
    var main_height_rem: u32 = undefined;

    var secondary_width: u32 = undefined;
    var secondary_height: u32 = undefined;
    var secondary_height_rem: u32 = undefined;

    if (main_count > 0 and secondary_count > 0) {
        main_width = @floatToInt(u32, main_factor * @intToFloat(f64, output_width));
        main_height = output_height / main_count;
        main_height_rem = output_height % main_count;

        secondary_width = output_width - main_width;
        secondary_height = output_height / secondary_count;
        secondary_height_rem = output_height % secondary_count;
    } else if (main_count > 0) {
        main_width = output_width;
        main_height = output_height / main_count;
        main_height_rem = output_height % main_count;
    } else if (secondary_width > 0) {
        main_width = 0;
        secondary_width = output_width;
        secondary_height = output_height / secondary_count;
        secondary_height_rem = output_height % secondary_count;
    }

    // Buffering the output makes things faster
    var stdout_buf = std.io.bufferedOutStream(std.io.getStdOut().outStream());
    const stdout = stdout_buf.outStream();

    var i: u32 = 0;
    while (i < num_views) : (i += 1) {
        var x: u32 = undefined;
        var y: u32 = undefined;
        var width: u32 = undefined;
        var height: u32 = undefined;

        if (i < main_count) {
            x = 0;
            y = i * main_height + if (i > 0) main_height_rem else 0;
            width = main_width;
            height = main_height + if (i == 0) main_height_rem else 0;
        } else {
            x = main_width;
            y = (i - main_count) * secondary_height + if (i > main_count) secondary_height_rem else 0;
            width = secondary_width;
            height = secondary_height + if (i == main_count) secondary_height_rem else 0;
        }

        switch (main_location) {
            .left => try stdout.print("{} {} {} {}\n", .{ x, y, width, height }),
            .right => try stdout.print("{} {} {} {}\n", .{ output_width - x - width, y, width, height }),
            .top => try stdout.print("{} {} {} {}\n", .{ y, x, height, width }),
            .bottom => try stdout.print("{} {} {} {}\n", .{ y, output_width - x - width, height, width }),
        }
    }

    try stdout_buf.flush();
}

fn printUsageAndExit() noreturn {
    const usage: []const u8 =
        \\Usage: rivertile left|right|top|bottom [args passed by river]
        \\
    ;

    std.debug.warn(usage, .{});
    std.os.exit(1);
}
