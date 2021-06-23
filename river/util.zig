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

/// The global general-purpose allocator used throughout river's code
pub const gpa = std.heap.c_allocator;

/// Take a pointer to c_void and cast it to a pointer to T. This function
/// exists to avoid having the verbosity of the required alignment casts all
/// over the code.
pub fn voidCast(comptime T: type, ptr: anytype) *T {
    // See https://github.com/ziglang/zig/issues/5618
    if (@TypeOf(ptr) != *c_void)
        @compileError("voidCast takes *c_void but " ++ @typeName(@TypeOf(ptr)) ++ " was provided");
    return @ptrCast(*T, @alignCast(@alignOf(*T), ptr));
}
