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
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const WindowManager = @import("WindowManager.zig");

const gpa = std.heap.c_allocator;

wm: *WindowManager,
window_v1: *river.WindowV1,
node_v1: *river.NodeV1,
link: wl.list.Link,

pub fn create(window_v1: *river.WindowV1, wm: *WindowManager) void {
    const window = gpa.create(Window) catch @panic("OOM");
    window.* = .{
        .wm = wm,
        .window_v1 = window_v1,
        .node_v1 = window_v1.getNode() catch @panic("OOM"),
        .link = undefined,
    };
    wm.windows.append(window);
    window_v1.setListener(*Window, handleEvent, window);
    window.node_v1.placeTop();
}

fn handleEvent(window_v1: *river.WindowV1, event: river.WindowV1.Event, window: *Window) void {
    assert(window.window_v1 == window_v1);
    switch (event) {
        .closed => {
            window_v1.destroy();

            window.link.remove();
            {
                var it = window.wm.seats.iterator(.forward);
                while (it.next()) |seat| {
                    if (seat.focused == window) {
                        seat.focused = null;
                        seat.focusNext();
                    }
                }
            }

            gpa.destroy(window);
        },
        .dimensions_hint => {},
        .dimensions => {},
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
