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

const Self = @This();

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

pub fn init(self: *Self, seat: *Seat, wlr_device: *wlr.InputDevice) !void {
    self.* = .{
        .device = undefined,
    };
    try self.device.init(seat, wlr_device);
    errdefer self.device.deinit();

    wlr_device.device.switch_device.events.toggle.add(&self.toggle);
}

pub fn deinit(self: *Self) void {
    self.toggle.link.remove();

    self.device.deinit();

    self.* = undefined;
}

fn handleToggle(listener: *wl.Listener(*wlr.Switch.event.Toggle), event: *wlr.Switch.event.Toggle) void {
    const self = @fieldParentPtr(Self, "toggle", listener);

    self.device.seat.handleActivity();

    var switch_type: Type = undefined;
    var switch_state: State = undefined;
    switch (event.switch_type) {
        .lid => {
            switch_type = .lid;
            switch_state = switch (event.switch_state) {
                .off => .{ .lid = .open },
                .on => .{ .lid = .close },
                .toggle => unreachable,
            };
        },
        .tablet_mode => {
            switch_type = .tablet;
            switch_state = switch (event.switch_state) {
                .off => .{ .tablet = .off },
                .on => .{ .tablet = .on },
                .toggle => unreachable,
            };
        },
    }

    self.device.seat.handleSwitchMapping(switch_type, switch_state);
}
