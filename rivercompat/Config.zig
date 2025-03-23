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

const Config = @This();

const std = @import("std");
const assert = std.debug.assert;

const gpa = std.heap.c_allocator;

border_width: u31 = 3,
border_color: u32 = 0x586e75,

main_count: u31 = 1,
main_location: enum { left, right, top, bottom } = .left,
outer_padding: u31 = 10,
window_padding: u31 = 10,
main_ratio: f64 = 0.60,
