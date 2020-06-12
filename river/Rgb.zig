// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Rishabh Das
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

r: u8,
g: u8,
b: u8,

pub fn parseString(self: *Self, string: []const u8) !void {
    if (string[0] != '#' or string.len != 7) return error.InvalidRgbFormat;

    const r = try std.fmt.parseInt(u8, string[1..3], 16);
    const g = try std.fmt.parseInt(u8, string[3..5], 16);
    const b = try std.fmt.parseInt(u8, string[5..7], 16);

    self.r = r;
    self.g = g;
    self.b = b;
}

pub fn getDecimalRgbaArray(self: Self) [4]f32 {
    return [4]f32{
        @intToFloat(f32, self.r) / 255.0,
        @intToFloat(f32, self.g) / 255.0,
        @intToFloat(f32, self.b) / 255.0,
        1.0,
    };
}
