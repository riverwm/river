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

const WindowManager = @import("WindowManager.zig");

const gpa = std.heap.c_allocator;

window_v1: *river.WindowV1,
node_v1: *river.NodeV1,
windowing: struct {
    new: bool = false,
    closed: bool = false,
},
rendering: struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
} = .{},
link: wl.list.Link,

shadow_surface: *wl.Surface,
shadow_decoration: *river.DecorationV1,
shadow_viewport: *wp.Viewport,
shadow_buffer: *wl.Buffer,

pub fn create(window_v1: *river.WindowV1, wm: *WindowManager) void {
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
        .windowing = .{ .new = true },
        .link = undefined,
        .shadow_surface = shadow_surface,
        .shadow_decoration = shadow_decoration,
        .shadow_viewport = shadow_viewport,
        .shadow_buffer = shadow_buffer,
    };
    wm.windows.append(window);
    window_v1.setListener(*Window, handleEvent, window);
}

fn handleEvent(window_v1: *river.WindowV1, event: river.WindowV1.Event, window: *Window) void {
    assert(window.window_v1 == window_v1);
    switch (event) {
        .closed => window.windowing.closed = true,
        .dimensions_hint => {},
        .dimensions => |args| {
            window.rendering.width = args.width;
            window.rendering.height = args.height;
        },
        .app_id => {},
        .title => {},
        .parent => {},
        .decoration_hint => {},
        .move_requested => {},
        .resize_requested => {},
        .show_window_menu_requested => {},
        .maximize_requested => {},
        .unmaximize_requested => {},
        .fullscreen_requested => {},
        .exit_fullscreen_requested => {},
        .minimize_requested => {},
    }
}

pub fn updateWindowing(window: *Window, wm: *WindowManager) void {
    if (window.windowing.closed) {
        window.window_v1.destroy();
        window.link.remove();
        {
            var it = wm.seats.iterator(.forward);
            while (it.next()) |seat| {
                if (seat.focused == window) {
                    seat.focused = null;
                    seat.focusNext();
                }
            }
        }
        gpa.destroy(window);
        return;
    }

    if (window.windowing.new) {
        window.node_v1.placeTop();
        window.window_v1.useSsd();

        const rgb = 0x586e75;
        window.window_v1.setBorders(
            .{ .left = true, .bottom = true, .top = false, .right = true },
            6, // width
            @as(u32, (rgb >> 16) & 0xff) * (0xffff_ffff / 0xff),
            @as(u32, (rgb >> 8) & 0xff) * (0xffff_ffff / 0xff),
            @as(u32, (rgb >> 0) & 0xff) * (0xffff_ffff / 0xff),
            0xffff_ffff,
        );

        {
            var it = wm.seats.iterator(.forward);
            while (it.next()) |seat| {
                seat.focus(window);
            }
        }

        window.node_v1.setPosition(20, 20);
        window.window_v1.proposeDimensions(400, 400);
    }

    window.windowing = .{};
}

pub fn updateRendering(window: *Window, wm: *WindowManager) void {
    _ = wm;
    {
        window.shadow_surface.attach(window.shadow_buffer, 0, 0);
        window.shadow_surface.damageBuffer(0, 0, math.maxInt(i32), math.maxInt(i32));
        window.shadow_viewport.setDestination(window.rendering.width, window.rendering.height);
        window.shadow_decoration.setOffset(20, 20);
        window.shadow_decoration.syncNextCommit();
        window.shadow_surface.commit();
    }
}
