// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2024 The River Developers
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

const Window = @This();

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const river = wayland.client.river;

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");

const wm = &@import("root").wm;
const gpa = std.heap.c_allocator;

window_v1: *river.WindowV1,
node_v1: *river.NodeV1,
pending: struct {
    new: bool = false,
    closed: bool = false,
},

box: Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

output: ?*Output = null,
tags: u32 = 0,

op: union(enum) {
    none,
    move: struct {
        seat: *Seat,
        start_x: i32,
        start_y: i32,
    },
    resize: struct {
        seat: *Seat,
        start_box: Box,
    },
} = .none,

link: wl.list.Link,
link_focus: wl.list.Link,
link_wm: wl.list.Link,

shadow_surface: *wl.Surface,
shadow_decoration: *river.DecorationV1,
shadow_viewport: *wp.Viewport,
shadow_buffer: *wl.Buffer,

pub fn create(window_v1: *river.WindowV1) void {
    const window = gpa.create(Window) catch @panic("OOM");

    const shadow_surface = wm.compositor.createSurface() catch @panic("OOM");
    const shadow_decoration = window_v1.getDecorationBelow(shadow_surface) catch @panic("OOM");
    const shadow_viewport = wm.viewporter.getViewport(shadow_surface) catch @panic("OOM");
    const shadow_buffer = wm.single_pixel.createU32RgbaBuffer(
        0,
        0,
        0,
        @intFromFloat(0.75 * math.maxInt(u32)),
    ) catch @panic("OOM");

    window.* = .{
        .window_v1 = window_v1,
        .node_v1 = window_v1.getNode() catch @panic("OOM"),
        .pending = .{ .new = true },
        .link = undefined,
        .link_focus = undefined,
        .link_wm = undefined,
        .shadow_surface = shadow_surface,
        .shadow_decoration = shadow_decoration,
        .shadow_viewport = shadow_viewport,
        .shadow_buffer = shadow_buffer,
    };
    wm.windows.append(window);
    window.link_focus.init();
    window.link_wm.init();

    window_v1.setListener(*Window, handleEvent, window);
}

fn handleEvent(window_v1: *river.WindowV1, event: river.WindowV1.Event, window: *Window) void {
    assert(window.window_v1 == window_v1);
    switch (event) {
        .closed => window.pending.closed = true,
        .dimensions_hint => {},
        .dimensions => |args| {
            window.box.width = @intCast(args.width);
            window.box.height = @intCast(args.height);
            window.box.width += 2 * wm.config.border_width;
            window.box.height += 2 * wm.config.border_width;
        },
        .app_id => {},
        .title => {},
        .parent => {},
        .decoration_hint => {},
        .pointer_move_requested => {},
        .pointer_resize_requested => {},
        .show_window_menu_requested => {},
        .maximize_requested => {},
        .unmaximize_requested => {},
        .fullscreen_requested => {},
        .exit_fullscreen_requested => {},
        .minimize_requested => {},
    }
}

pub fn manage(window: *Window) void {
    if (window.pending.closed) {
        window.window_v1.destroy();
        window.link.remove();
        window.link_focus.remove();
        window.link_wm.remove();
        {
            var it = wm.seats.iterator(.forward);
            while (it.next()) |seat| {
                if (seat.focused == window) {
                    seat.focus(null);
                }
            }
        }
        window.shadow_decoration.destroy();
        window.shadow_viewport.destroy();
        window.shadow_surface.destroy();
        window.shadow_buffer.destroy();
        gpa.destroy(window);
        return;
    }

    if (window.pending.new) {
        window.window_v1.useSsd();

        if (if (wm.seats.first()) |seat| seat.focused_output else null) |output| {
            window.output = output;
            window.tags = output.tags;
            window.link_wm.remove();
            window.link_focus.remove();
            output.stack_focus.prepend(window);
            output.stack_wm.prepend(window);
            {
                var it = wm.seats.iterator(.forward);
                while (it.next()) |seat| {
                    seat.focus(window);
                }
            }
        } else {
            window.tags = (1 << 0); // XXX
            window.link_wm.remove();
            window.link_focus.remove();
            wm.fallback_stack_focus.prepend(window);
            wm.fallback_stack_wm.prepend(window);
        }
    }

    switch (window.op) {
        .none, .move => {},
        .resize => |op| {
            window.window_v1.setTiled(.{ .top = false, .bottom = false, .left = false, .right = false });
            // resize from top left corner
            window.proposeDimensions(
                @max(1, op.start_box.width - op.seat.op.?.dx),
                @max(1, op.start_box.height - op.seat.op.?.dy),
            );
        },
    }

    window.pending = .{};
}

pub fn render(window: *Window) void {
    if (window.box.width != 0 and window.box.height != 0) {
        window.shadow_surface.attach(window.shadow_buffer, 0, 0);
        window.shadow_surface.damageBuffer(0, 0, math.maxInt(i32), math.maxInt(i32));
        window.shadow_viewport.setDestination(window.box.width + 2 * wm.config.border_width, window.box.height + 2 * wm.config.border_width);
        window.shadow_decoration.setOffset(10 - wm.config.border_width, 10 - wm.config.border_width);
        window.shadow_decoration.syncNextCommit();
        window.shadow_surface.commit();
    }

    switch (window.op) {
        .none => {},
        .move => |op| {
            window.setPosition(
                op.seat.op.?.dx + op.start_x,
                op.seat.op.?.dy + op.start_y,
            );
        },
        .resize => |op| {
            // resize from top left corner
            window.setPosition(
                op.start_box.x + (@as(i32, op.start_box.width) - window.box.width),
                op.start_box.y + (@as(i32, op.start_box.height) - window.box.height),
            );
        },
    }

    {
        var it = wm.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.hovered == window) {
                window.setBorders(wm.config.border_color_hovered);
                break;
            } else if (seat.focused == window) {
                window.setBorders(wm.config.border_color_focused);
                break;
            }
        } else {
            window.setBorders(wm.config.border_color_unfocused);
        }
    }
}

fn setBorders(window: *Window, rgb: u32) void {
    window.window_v1.setBorders(
        .{ .left = true, .bottom = true, .top = true, .right = true },
        wm.config.border_width,
        @as(u32, (rgb >> 16) & 0xff) * (0xffff_ffff / 0xff),
        @as(u32, (rgb >> 8) & 0xff) * (0xffff_ffff / 0xff),
        @as(u32, (rgb >> 0) & 0xff) * (0xffff_ffff / 0xff),
        0xffff_ffff,
    );
}

pub const Box = struct {
    x: i32,
    y: i32,
    width: u31,
    height: u31,
};

pub fn layout(window: *Window, box: Box) void {
    window.setPosition(box.x, box.y);
    window.proposeDimensions(box.width, box.height);
}

pub fn setPosition(window: *Window, x: i32, y: i32) void {
    window.box.x = x;
    window.box.y = y;
    window.node_v1.setPosition(x + wm.config.border_width, y + wm.config.border_width);
}

pub fn proposeDimensions(window: *Window, width: u31, height: u31) void {
    window.box.width = width;
    window.box.height = height;
    window.window_v1.proposeDimensions(
        @max(1, @as(i32, width) - 2 * wm.config.border_width),
        @max(1, @as(i32, height) - 2 * wm.config.border_width),
    );
}
