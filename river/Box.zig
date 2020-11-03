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

const wlr = @import("wlroots");

x: i32,
y: i32,
width: u32,
height: u32,

pub fn fromWlrBox(wlr_box: wlr.Box) Self {
    return Self{
        .x = @intCast(i32, wlr_box.x),
        .y = @intCast(i32, wlr_box.y),
        .width = @intCast(u32, wlr_box.width),
        .height = @intCast(u32, wlr_box.height),
    };
}

pub fn toWlrBox(self: Self) wlr.Box {
    return wlr.Box{
        .x = @intCast(c_int, self.x),
        .y = @intCast(c_int, self.y),
        .width = @intCast(c_int, self.width),
        .height = @intCast(c_int, self.height),
    };
}
