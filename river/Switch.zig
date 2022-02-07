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

seat: *Seat,
input_device: *wlr.InputDevice,

switch_device: wl.Listener(*wlr.Switch.event.Toggle) = wl.Listener(*wlr.Switch.event.Toggle).init(handleToggle),
destroy: wl.Listener(*wlr.Switch) = wl.Listener(*wlr.Switch).init(handleDestroy),

pub fn init(self: *Self, seat: *Seat, input_device: *wlr.InputDevice) void {
    self.* = .{
        .seat = seat,
        .input_device = input_device,
    };

    const wlr_switch = self.input_device.device.switch_device;

    wlr_switch.events.toggle.add(&self.switch_device);
}

pub fn deinit(self: *Self) void {
    self.destroy.link.remove();
}

fn handleToggle(listener: *wl.Listener(*wlr.Switch.event.Toggle), event: *wlr.Switch.event.Toggle) void {
    // This event is raised when the lid witch or the tablet mode switch is toggled.
    const self = @fieldParentPtr(Self, "switch_device", listener);

    self.seat.handleActivity();

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

    self.seat.handleSwitchMapping(switch_type, switch_state);
}

fn handleDestroy(listener: *wl.Listener(*wlr.Switch), _: *wlr.Switch) void {
    const self = @fieldParentPtr(Self, "destroy", listener);
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);

    self.seat.switches.remove(node);
    self.deinit();
    util.gpa.destroy(node);
}
