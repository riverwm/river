// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2023 The River Developers
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

const std = @import("std");
const math = std.math;
const wlr = @import("wlroots");

const Vector = @This();

x: i32,
y: i32,

pub fn positionOfBox(box: wlr.Box) Vector {
    return .{
        .x = box.x + @divFloor(box.width, 2),
        .y = box.y + @divFloor(box.height, 2),
    };
}

/// Returns the difference between two vectors.
pub fn diff(a: Vector, b: Vector) Vector {
    return .{
        .x = b.x - a.x,
        .y = b.y - a.y,
    };
}

/// Returns the direction of the vector.
pub fn direction(v: Vector) ?wlr.OutputLayout.Direction {
    // A zero length vector has no direction
    if (v.x == 0 and v.y == 0) return null;

    if (@abs(v.y) > @abs(v.x)) {
        // Careful: We are operating in a Y-inverted coordinate system.
        return if (v.y > 0) .down else .up;
    } else {
        return if (v.x > 0) .right else .left;
    }
}

/// Returns the length of the vector.
pub fn length(v: Vector) u31 {
    return math.sqrt(@as(u31, @intCast((v.x *| v.x) +| (v.y *| v.y))));
}
