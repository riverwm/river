// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
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

const Self = @This();

const std = @import("std");

const c = @import("c.zig");

const Box = @import("Box.zig");
const View = @import("View.zig");

pub fn needsConfigure(self: Self) bool {
    unreachable;
}

pub fn configure(self: Self, pending_box: Box) void {
    unreachable;
}

pub fn setActivated(self: Self, activated: bool) void {
    unreachable;
}

pub fn setFullscreen(self: Self, fullscreen: bool) void {
    unreachable;
}

pub fn close(self: Self) void {
    unreachable;
}

pub fn forEachSurface(
    self: Self,
    iterator: c.wlr_surface_iterator_func_t,
    user_data: ?*c_void,
) void {
    unreachable;
}

pub fn surfaceAt(self: Self, ox: f64, oy: f64, sx: *f64, sy: *f64) ?*c.wlr_surface {
    unreachable;
}

pub fn getTitle(self: Self) [*:0]const u8 {
    unreachable;
}

pub fn getConstraints(self: Self) View.Constraints {
    unreachable;
}
