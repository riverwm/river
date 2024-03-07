// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2022 The River Developers
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

const Switch = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");
const InputDevice = @import("InputDevice.zig");

const log = std.log.scoped(.switch_device);

pub const Type = enum {
    lid,
    tablet,
};

pub const State = union(Type) {
    lid: LidState,
    tablet: TabletState,
};

pub const LidState = enum {
    open,
    close,
};

pub const TabletState = enum {
    off,
    on,
};

device: InputDevice,

toggle: wl.Listener(*wlr.Switch.event.Toggle) = wl.Listener(*wlr.Switch.event.Toggle).init(handleToggle),

pub fn init(switch_device: *Switch, seat: *Seat, wlr_device: *wlr.InputDevice) !void {
    switch_device.* = .{
        .device = undefined,
    };
    try switch_device.device.init(seat, wlr_device);
    errdefer switch_device.device.deinit();

    wlr_device.toSwitch().events.toggle.add(&switch_device.toggle);
}

pub fn deinit(switch_device: *Switch) void {
    switch_device.toggle.link.remove();

    switch_device.device.deinit();

    switch_device.* = undefined;
}

fn handleToggle(listener: *wl.Listener(*wlr.Switch.event.Toggle), event: *wlr.Switch.event.Toggle) void {
    const switch_device: *Switch = @fieldParentPtr("toggle", listener);

    switch_device.device.seat.handleActivity();

    var switch_type: Type = undefined;
    var switch_state: State = undefined;
    switch (event.switch_type) {
        .lid => {
            switch_type = .lid;
            switch_state = switch (event.switch_state) {
                .off => .{ .lid = .open },
                .on => .{ .lid = .close },
            };
        },
        .tablet_mode => {
            switch_type = .tablet;
            switch_state = switch (event.switch_state) {
                .off => .{ .tablet = .off },
                .on => .{ .tablet = .on },
            };
        },
    }

    switch_device.device.seat.handleSwitchMapping(switch_type, switch_state);
}
