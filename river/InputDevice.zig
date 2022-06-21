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

const InputDevice = @This();

const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");
const Keyboard = @import("Keyboard.zig");
const Switch = @import("Switch.zig");

const log = std.log.scoped(.input_manager);

seat: *Seat,
wlr_device: *wlr.InputDevice,

destroy: wl.Listener(*wlr.InputDevice) = wl.Listener(*wlr.InputDevice).init(handleDestroy),

/// Careful: The identifier is not unique! A physical input device may have
/// multiple logical input devices with the exact same vendor id, product id
/// and name. However identifiers of InputConfigs are unique.
identifier: []const u8,

/// InputManager.devices
link: wl.list.Link,

pub fn init(device: *InputDevice, seat: *Seat, wlr_device: *wlr.InputDevice) !void {
    const device_type: []const u8 = switch (wlr_device.type) {
        .switch_device => "switch",
        else => @tagName(wlr_device.type),
    };

    const identifier = try std.fmt.allocPrint(
        util.gpa,
        "{s}-{}-{}-{s}",
        .{
            device_type,
            wlr_device.vendor,
            wlr_device.product,
            mem.trim(u8, mem.span(wlr_device.name), &ascii.spaces),
        },
    );
    errdefer util.gpa.free(identifier);

    for (identifier) |*char| {
        if (!ascii.isGraph(char.*)) {
            char.* = '_';
        }
    }

    device.* = .{
        .seat = seat,
        .wlr_device = wlr_device,
        .identifier = identifier,
        .link = undefined,
    };

    wlr_device.events.destroy.add(&device.destroy);

    // Apply any matching input device configuration.
    for (server.input_manager.configs.items) |*input_config| {
        if (mem.eql(u8, input_config.identifier, identifier)) {
            input_config.apply(device);
        }
    }

    server.input_manager.devices.append(device);
    seat.updateCapabilities();

    log.debug("new input device: {s}", .{identifier});
}

pub fn deinit(device: *InputDevice) void {
    device.destroy.link.remove();

    util.gpa.free(device.identifier);

    device.link.remove();
    device.seat.updateCapabilities();

    device.* = undefined;
}

fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    const device = @fieldParentPtr(InputDevice, "destroy", listener);

    log.debug("removed input device: {s}", .{device.identifier});

    switch (device.wlr_device.type) {
        .keyboard => {
            const keyboard = @fieldParentPtr(Keyboard, "device", device);
            keyboard.deinit();
            util.gpa.destroy(keyboard);
        },
        .pointer => {
            device.deinit();
            util.gpa.destroy(device);
        },
        .switch_device => {
            const switch_device = @fieldParentPtr(Switch, "device", device);
            switch_device.deinit();
            util.gpa.destroy(switch_device);
        },
        .touch, .tablet_tool, .tablet_pad => unreachable,
    }
}
