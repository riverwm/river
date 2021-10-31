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

const std = @import("std");
const os = std.os;
const math = std.math;

/// The global general-purpose allocator used throughout river's code
pub const gpa = std.heap.c_allocator;

/// like @intCast(), but only for casting to a type with fewer bits and casting
/// a value too large for the target type is not undefined.
pub fn safeIntDownCast(comptime T: type, val: anytype) T {
    comptime {
        const out_info = @typeInfo(T);
        const in_info = @typeInfo(@TypeOf(val));
        if (out_info != .Int or in_info != .Int) @compileError("only integer types are supported");
        if (out_info.Int.bits > in_info.Int.bits) @compileError("out type must be smaller than in type");
    }
    const max = std.math.maxInt(T);
    if (val >= max) return max;
    return @intCast(T, val);
}
