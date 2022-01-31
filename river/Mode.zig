// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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

const Self = @This();

const std = @import("std");
const util = @import("util.zig");

const Mapping = @import("Mapping.zig");
const PointerMapping = @import("PointerMapping.zig");

// TODO: use unmanaged array lists here to save memory
mappings: std.ArrayList(Mapping),
pointer_mappings: std.ArrayList(PointerMapping),

pub fn init() Self {
    return .{
        .mappings = std.ArrayList(Mapping).init(util.gpa),
        .pointer_mappings = std.ArrayList(PointerMapping).init(util.gpa),
    };
}

pub fn deinit(self: Self) void {
    for (self.mappings.items) |m| m.deinit();
    self.mappings.deinit();
    self.pointer_mappings.deinit();
}
