// SPDX-FileCopyrightText: © 2024 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const Tablet = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const InputDevice = @import("InputDevice.zig");
const Seat = @import("Seat.zig");

device: InputDevice,
wp_tablet: *wlr.TabletV2Tablet,

pub fn create(seat: *Seat, wlr_device: *wlr.InputDevice, virtual: bool) !*Tablet {
    assert(wlr_device.type == .tablet);

    const tablet = try util.gpa.create(Tablet);
    errdefer util.gpa.destroy(tablet);

    const tablet_manager = server.input_manager.tablet_manager;

    tablet.* = .{
        .device = undefined,
        .wp_tablet = try tablet_manager.createTabletV2Tablet(seat.wlr_seat, wlr_device),
    };
    try tablet.device.init(seat, wlr_device, virtual);
    errdefer tablet.device.deinit();

    return tablet;
}

pub fn destroy(tablet: *Tablet) void {
    tablet.device.deinit();
    util.gpa.destroy(tablet);
}
