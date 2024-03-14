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

const Mode = @This();

const std = @import("std");
const util = @import("util.zig");

const Mapping = @import("Mapping.zig");
const PointerMapping = @import("PointerMapping.zig");
const SwitchMapping = @import("SwitchMapping.zig");

name: [:0]const u8,
mappings: std.ArrayListUnmanaged(Mapping) = .{},
pointer_mappings: std.ArrayListUnmanaged(PointerMapping) = .{},
switch_mappings: std.ArrayListUnmanaged(SwitchMapping) = .{},

pub fn deinit(mode: *Mode) void {
    util.gpa.free(mode.name);
    for (mode.mappings.items) |m| m.deinit();
    mode.mappings.deinit(util.gpa);
    for (mode.pointer_mappings.items) |*m| m.deinit();
    mode.pointer_mappings.deinit(util.gpa);
    mode.switch_mappings.deinit(util.gpa);
}
