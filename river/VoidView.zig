// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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
const wlr = @import("wlroots");

const Box = @import("Box.zig");
const View = @import("View.zig");

pub fn needsConfigure(_: Self) bool {
    unreachable;
}

pub fn configure(_: Self) void {
    unreachable;
}

pub fn setActivated(_: Self, _: bool) void {
    unreachable;
}

pub fn setFullscreen(_: Self, _: bool) void {
    unreachable;
}

pub fn close(_: Self) void {
    unreachable;
}

pub fn surfaceAt(_: Self, _: f64, _: f64, _: *f64, _: *f64) ?*wlr.Surface {
    unreachable;
}

pub fn getTitle(_: Self) ?[*:0]const u8 {
    unreachable;
}

pub fn getAppId(_: Self) ?[*:0]const u8 {
    unreachable;
}

pub fn getConstraints(_: Self) View.Constraints {
    unreachable;
}
