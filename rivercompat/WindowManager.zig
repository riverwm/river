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

const WindowManager = @This();

const std = @import("std");
const assert = std.debug.assert;
const main = @import("main.zig");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const river = wayland.client.river;

const Seat = @import("Seat.zig");
const ShellSurface = @import("ShellSurface.zig");
const Window = @import("Window.zig");

wm_v1: *river.WindowManagerV1,
compositor: *wl.Compositor,
viewporter: *wp.Viewporter,
single_pixel: *wp.SinglePixelBufferManagerV1,

windows: wl.list.Head(Window, .link),
seats: wl.list.Head(Seat, .link),
shell_surfaces: wl.list.Head(ShellSurface, .link),

pub fn init(
    wm: *WindowManager,
    wm_v1: *river.WindowManagerV1,
    compositor: *wl.Compositor,
    viewporter: *wp.Viewporter,
    single_pixel: *wp.SinglePixelBufferManagerV1,
) void {
    wm.* = .{
        .wm_v1 = wm_v1,
        .compositor = compositor,
        .viewporter = viewporter,
        .single_pixel = single_pixel,
        .windows = undefined,
        .seats = undefined,
        .shell_surfaces = undefined,
    };
    wm.windows.init();
    wm.seats.init();
    wm.shell_surfaces.init();

    wm_v1.setListener(*WindowManager, handleEvent, wm);

    ShellSurface.create(wm);
}

fn handleEvent(wm_v1: *river.WindowManagerV1, event: river.WindowManagerV1.Event, wm: *WindowManager) void {
    assert(wm.wm_v1 == wm_v1);
    switch (event) {
        .unavailable => main.fatal("another window manager is already running", .{}),
        .finished => unreachable, // We never send river_window_manager_v1.stop
        .update_windowing_start => {
            wm.updateWindowing();
            wm_v1.updateWindowingFinish();
        },
        .update_rendering_start => {
            wm.updateRendering();
            wm_v1.updateWindowingFinish();
        },
        .session_locked => {},
        .session_unlocked => {},
        .window => |args| Window.create(args.id, wm),
        .output => |args| {
            _ = args;
        },
        .seat => |args| {
            Seat.create(wm, args.id);
        },
    }
}

fn updateWindowing(wm: *WindowManager) void {
    {
        var it = wm.seats.iterator(.forward);
        while (it.next()) |seat| {
            seat.updateWindowing();
        }
    }
    {
        var x: i32 = 0;
        var y: i32 = 0;
        var it = wm.windows.iterator(.forward);
        while (it.next()) |window| {
            window.updateWindowing(wm);

            window.node_v1.setPosition(x, y);
            window.window_v1.proposeDimensions(400, 400);
            x += 40;
            y += 40;
        }
    }
    {
        var it = wm.shell_surfaces.iterator(.forward);
        while (it.next()) |shell_surface| {
            shell_surface.updateWindowing(wm);
        }
    }
}

fn updateRendering(wm: *WindowManager) void {
    _ = wm;
}
