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

const globber = @import("globber");

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
            mem.trim(u8, mem.sliceTo(wlr_device.name, 0), &ascii.whitespace),
        },
    );
    errdefer util.gpa.free(identifier);

    for (identifier) |*char| {
        if (!ascii.isPrint(char.*) or ascii.isWhitespace(char.*)) {
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

    // Keyboard groups are implemented as "virtual" input devices which we don't want to expose
    // in riverctl list-inputs as they can't be configured.
    if (!isKeyboardGroup(wlr_device)) {
        // Apply all matching input device configuration.
        for (server.input_manager.configs.items) |input_config| {
            if (globber.match(identifier, input_config.glob)) {
                input_config.apply(device);
            }
        }

        server.input_manager.devices.append(device);
        seat.updateCapabilities();
    }

    log.debug("new input device: {s}", .{identifier});
}

pub fn deinit(device: *InputDevice) void {
    device.destroy.link.remove();

    util.gpa.free(device.identifier);

    if (!isKeyboardGroup(device.wlr_device)) {
        device.link.remove();
        device.seat.updateCapabilities();
    }

    device.* = undefined;
}

fn isKeyboardGroup(wlr_device: *wlr.InputDevice) bool {
    return wlr_device.type == .keyboard and
        wlr.KeyboardGroup.fromKeyboard(wlr_device.toKeyboard()) != null;
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
        .pointer, .touch => {
            device.deinit();
            util.gpa.destroy(device);
        },
        .switch_device => {
            const switch_device = @fieldParentPtr(Switch, "device", device);
            switch_device.deinit();
            util.gpa.destroy(switch_device);
        },
        .tablet_tool, .tablet_pad => unreachable,
    }
}
