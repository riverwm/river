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

const ShellSurface = @This();

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const river = wayland.client.river;

const WindowManager = @import("WindowManager.zig");

const gpa = std.heap.c_allocator;

const State = struct {
    new: bool = false,
};

surface: *wl.Surface,
viewport: *wp.Viewport,
shell_surface_v1: *river.ShellSurfaceV1,
node: *river.NodeV1,
pending: State,
link: wl.list.Link,

pub fn create(wm: *WindowManager) void {
    const shell_surface = gpa.create(ShellSurface) catch @panic("OOM");
    const surface = wm.compositor.createSurface() catch @panic("OOM");
    const viewport = wm.viewporter.getViewport(surface) catch @panic("OOM");
    const shell_surface_v1 = wm.wm_v1.getShellSurface(surface) catch @panic("OOM");

    shell_surface.* = .{
        .surface = surface,
        .viewport = viewport,
        .shell_surface_v1 = shell_surface_v1,
        .node = shell_surface_v1.getNode() catch @panic("OOM"),
        .pending = .{ .new = true },
        .link = undefined,
    };
    wm.shell_surfaces.append(shell_surface);
}

pub fn updateWindowing(shell_surface: *ShellSurface, wm: *WindowManager) void {
    if (shell_surface.pending.new) {
        shell_surface.node.placeBottom();
        shell_surface.node.setPosition(0, 0);
        shell_surface.shell_surface_v1.syncNextCommit();

        const rgb = 0xfdf6e3;

        const buffer = wm.single_pixel.createU32RgbaBuffer(
            @as(u32, (rgb >> 16) & 0xff) * (0xffff_ffff / 0xff),
            @as(u32, (rgb >> 8) & 0xff) * (0xffff_ffff / 0xff),
            @as(u32, (rgb >> 0) & 0xff) * (0xffff_ffff / 0xff),
            0xffff_ffff,
        ) catch @panic("OOM");
        defer buffer.destroy();

        shell_surface.surface.attach(buffer, 0, 0);

        shell_surface.surface.damageBuffer(0, 0, math.maxInt(i32), math.maxInt(i32));
        shell_surface.viewport.setDestination(math.maxInt(i32) / 2, math.maxInt(i32) / 2);
        shell_surface.surface.commit();
    }
}
