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

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const ShellSurface = @import("ShellSurface.zig");
const Window = @import("Window.zig");

wm_v1: *river.WindowManagerV1,
compositor: *wl.Compositor,
viewporter: *wp.Viewporter,
single_pixel: *wp.SinglePixelBufferManagerV1,

session_locked: bool = false,

windows: wl.list.Head(Window, .link),
seats: wl.list.Head(Seat, .link),
outputs: wl.list.Head(Output, .link),
shell_surfaces: wl.list.Head(ShellSurface, .link),

fallback_stack_wm: wl.list.Head(Window, .link_wm),
fallback_stack_focus: wl.list.Head(Window, .link_focus),

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
        .outputs = undefined,
        .shell_surfaces = undefined,
        .fallback_stack_wm = undefined,
        .fallback_stack_focus = undefined,
    };
    wm.windows.init();
    wm.seats.init();
    wm.outputs.init();
    wm.shell_surfaces.init();
    wm.fallback_stack_wm.init();
    wm.fallback_stack_focus.init();

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
            wm_v1.updateRenderingFinish();
        },
        .session_locked => wm.session_locked = true,
        .session_unlocked => wm.session_locked = false,
        .window => |args| Window.create(args.id, wm),
        .output => |args| Output.create(wm, args.id),
        .seat => |args| Seat.create(wm, args.id),
    }
}

fn updateWindowing(wm: *WindowManager) void {
    {
        var it = wm.outputs.iterator(.forward);
        while (it.next()) |output| {
            output.updateWindowing(wm);
        }
    }
    {
        var it = wm.seats.iterator(.forward);
        while (it.next()) |seat| {
            seat.updateWindowing();
        }
    }
    {
        var it = wm.windows.safeIterator(.forward);
        while (it.next()) |window| {
            window.updateWindowing(wm);
        }
    }
    {
        var it = wm.shell_surfaces.iterator(.forward);
        while (it.next()) |shell_surface| {
            shell_surface.updateWindowing(wm);
        }
    }

    {
        var it = wm.outputs.iterator(.forward);
        while (it.next()) |output| {
            output.layout();
        }
    }
}

fn updateRendering(wm: *WindowManager) void {
    {
        var it = wm.windows.iterator(.forward);
        while (it.next()) |window| {
            window.updateRendering(wm);
        }
    }
}
