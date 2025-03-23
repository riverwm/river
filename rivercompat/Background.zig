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

const Background = @This();

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const river = wayland.client.river;

const wm = &@import("root").wm;

const State = struct {
    new: bool = false,
};

surface: *wl.Surface,
viewport: *wp.Viewport,
shell_surface_v1: *river.ShellSurfaceV1,
node: *river.NodeV1,
pending: State,

pub fn init(background: *Background) void {
    const surface = wm.compositor.createSurface() catch @panic("OOM");
    const viewport = wm.viewporter.getViewport(surface) catch @panic("OOM");
    const shell_surface_v1 = wm.wm_v1.getShellSurface(surface) catch @panic("OOM");

    background.* = .{
        .surface = surface,
        .viewport = viewport,
        .shell_surface_v1 = shell_surface_v1,
        .node = shell_surface_v1.getNode() catch @panic("OOM"),
        .pending = .{ .new = true },
    };
}

pub fn updateWindowing(background: *Background) void {
    if (background.pending.new) {
        background.node.placeBottom();
        background.node.setPosition(0, 0);
        background.shell_surface_v1.syncNextCommit();

        const rgb = 0xfdf6e3;

        const buffer = wm.single_pixel.createU32RgbaBuffer(
            @as(u32, (rgb >> 16) & 0xff) * (0xffff_ffff / 0xff),
            @as(u32, (rgb >> 8) & 0xff) * (0xffff_ffff / 0xff),
            @as(u32, (rgb >> 0) & 0xff) * (0xffff_ffff / 0xff),
            0xffff_ffff,
        ) catch @panic("OOM");
        defer buffer.destroy();

        background.surface.attach(buffer, 0, 0);

        background.surface.damageBuffer(0, 0, math.maxInt(i32), math.maxInt(i32));
        background.viewport.setDestination(math.maxInt(i32) / 2, math.maxInt(i32) / 2);
        background.surface.commit();
    }
}
