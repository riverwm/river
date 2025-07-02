// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2025 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const Output = @This();

const std = @import("std");
const assert = std.debug.assert;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Window = @import("Window.zig");

const wm = &@import("root").wm;
const gpa = std.heap.c_allocator;

output_v1: *river.OutputV1,
pending: struct {
    new: bool = false,
    removed: bool = false,
},

x: i32 = 0,
y: i32 = 0,
width: u31 = 0,
height: u31 = 0,

tags: u32 = (1 << 0),
stack_focus: wl.list.Head(Window, .link_focus),
stack_wm: wl.list.Head(Window, .link_wm),

link: wl.list.Link,

pub fn create(output_v1: *river.OutputV1) void {
    const output = gpa.create(Output) catch @panic("OOM");
    output.* = .{
        .output_v1 = output_v1,
        .pending = .{ .new = true },
        .stack_focus = undefined,
        .stack_wm = undefined,
        .link = undefined,
    };
    output.stack_focus.init();
    output.stack_wm.init();
    wm.outputs.append(output);

    output_v1.setListener(*Output, handleEvent, output);
}

fn handleEvent(output_v1: *river.OutputV1, event: river.OutputV1.Event, output: *Output) void {
    assert(output.output_v1 == output_v1);
    switch (event) {
        .removed => output.pending.removed = true,
        .wl_output => {},
        .position => |args| {
            output.x = args.x;
            output.y = args.y;
        },
        .dimensions => |args| {
            output.width = @intCast(args.width);
            output.height = @intCast(args.height);
        },
    }
}

pub fn updateWindowing(output: *Output) void {
    if (output.pending.removed) {
        // XXX
        output.output_v1.destroy();
        gpa.destroy(output);
    }

    if (output.pending.new) {
        {
            var it = wm.fallback_stack_wm.iterator(.forward);
            while (it.next()) |window| {
                window.output = output;
                window.link_wm.remove();
                window.link_focus.remove();
                output.stack_focus.prepend(window);
                output.stack_wm.prepend(window);
            }
        }
        {
            var it = wm.seats.iterator(.forward);
            while (it.next()) |seat| {
                if (seat.focused_output == null) {
                    seat.focused_output = output;
                    seat.focus(null);
                }
            }
        }
    }

    output.pending = .{};
}

pub fn layout(output: *Output) void {
    var count: u31 = 0;
    {
        var it = output.stack_wm.iterator(.forward);
        while (it.next()) |window| {
            if (window.tags & output.tags != 0 and window.op == .none) {
                count += 1;
            }
        }
    }
    if (count == 0) return;

    const main_count = @min(wm.config.main_count, count);
    const secondary_count = count -| main_count;

    const usable_width = switch (wm.config.main_location) {
        .left, .right => output.width -| (2 *| wm.config.outer_padding),
        .top, .bottom => output.height -| (2 *| wm.config.outer_padding),
    };
    const usable_height = switch (wm.config.main_location) {
        .left, .right => output.height -| (2 *| wm.config.outer_padding),
        .top, .bottom => output.width -| (2 *| wm.config.outer_padding),
    };

    // to make things pixel-perfect, we make the first main and first secondary
    // view slightly larger if the height is not evenly divisible
    var main_width: u31 = undefined;
    var main_height: u31 = undefined;
    var main_height_rem: u31 = undefined;

    var secondary_width: u31 = undefined;
    var secondary_height: u31 = undefined;
    var secondary_height_rem: u31 = undefined;

    if (secondary_count > 0) {
        main_width = @intFromFloat(wm.config.main_ratio * @as(f64, @floatFromInt(usable_width)));
        main_height = usable_height / main_count;
        main_height_rem = usable_height % main_count;

        secondary_width = usable_width - main_width;
        secondary_height = usable_height / secondary_count;
        secondary_height_rem = usable_height % secondary_count;
    } else {
        main_width = usable_width;
        main_height = usable_height / main_count;
        main_height_rem = usable_height % main_count;
    }

    {
        var i: u31 = 0;
        var it = output.stack_wm.iterator(.forward);
        while (it.next()) |window| {
            if (window.tags & output.tags == 0) continue;
            if (window.op != .none) continue;
            defer i += 1;

            var x: i32 = undefined;
            var y: i32 = undefined;
            var width: u31 = undefined;
            var height: u31 = undefined;

            if (i < main_count) {
                x = 0;
                y = (i * main_height) + if (i > 0) main_height_rem else 0;
                width = main_width;
                height = main_height + if (i == 0) main_height_rem else 0;
            } else {
                x = main_width;
                y = (i - main_count) * secondary_height + if (i > main_count) secondary_height_rem else 0;
                width = secondary_width;
                height = secondary_height + if (i == main_count) secondary_height_rem else 0;
            }

            x +|= wm.config.window_padding;
            y +|= wm.config.window_padding;
            width -|= 2 *| wm.config.window_padding;
            height -|= 2 *| wm.config.window_padding;

            switch (wm.config.main_location) {
                .left => window.layout(.{
                    .x = x +| wm.config.outer_padding,
                    .y = y +| wm.config.outer_padding,
                    .width = width,
                    .height = height,
                }),
                .right => window.layout(.{
                    .x = usable_width - width - x +| wm.config.outer_padding,
                    .y = y +| wm.config.outer_padding,
                    .width = width,
                    .height = height,
                }),
                .top => window.layout(.{
                    .x = y +| wm.config.outer_padding,
                    .y = x +| wm.config.outer_padding,
                    .width = height,
                    .height = width,
                }),
                .bottom => window.layout(.{
                    .x = y +| wm.config.outer_padding,
                    .y = usable_width - width - x +| wm.config.outer_padding,
                    .width = height,
                    .height = width,
                }),
            }
            window.window_v1.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
        }
    }

    {
        var it = output.stack_focus.iterator(.reverse);
        while (it.next()) |window| {
            window.node_v1.placeTop();
        }
    }
}
