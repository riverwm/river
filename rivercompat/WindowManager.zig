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

const main = @import("main.zig");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

wm_v1: *river.WindowManagerV1,

pub fn init(wm: *WindowManager, wm_v1: *river.WindowManagerV1) void {
    wm.* = .{
        .wm_v1 = wm_v1,
    };

    wm_v1.setListener(*WindowManager, handleEvent, wm);
}

fn handleEvent(wm_v1: *river.WindowManagerV1, event: river.WindowManagerV1.Event, _: *WindowManager) void {
    switch (event) {
        .unavailable => main.fatal("another window manager is already running", .{}),
        .finished => unreachable, // We never send river_window_manager_v1.stop
        .update => |args| {
            wm_v1.ackUpdate(args.serial);
            wm_v1.commit();
        },
        .session_locked => {},
        .session_unlocked => {},
        .window => |args| {
            args.id.proposeDimensions(400, 400);
        },
        .output => |args| {
            _ = args;
        },
    }
}
