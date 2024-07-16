// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2024 The River Developers
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

const Tablet = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const InputDevice = @import("InputDevice.zig");
const Seat = @import("Seat.zig");
const TabletTool = @import("TabletTool.zig");

device: InputDevice,
wp_tablet: *wlr.TabletV2Tablet,

output_mapping: ?*wlr.Output = null,

pub fn create(seat: *Seat, wlr_device: *wlr.InputDevice) !void {
    assert(wlr_device.type == .tablet);

    const tablet = try util.gpa.create(Tablet);
    errdefer util.gpa.destroy(tablet);

    const tablet_manager = server.input_manager.tablet_manager;

    tablet.* = .{
        .device = undefined,
        .wp_tablet = try tablet_manager.createTabletV2Tablet(seat.wlr_seat, wlr_device),
    };
    try tablet.device.init(seat, wlr_device);
    errdefer tablet.device.deinit();
}

pub fn destroy(tablet: *Tablet) void {
    tablet.device.deinit();
    util.gpa.destroy(tablet);
}
