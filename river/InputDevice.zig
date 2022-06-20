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

const log = std.log.scoped(.input_manager);

device: *wlr.InputDevice,
destroy: wl.Listener(*wlr.InputDevice) = wl.Listener(*wlr.InputDevice).init(handleDestroy),

/// Careful: The identifier is not unique! A physical input device may have
/// multiple logical input devices with the exact same vendor id, product id
/// and name. However identifiers of InputConfigs are unique.
identifier: []const u8,

pub fn init(self: *InputDevice, device: *wlr.InputDevice) !void {
    const identifier = try std.fmt.allocPrint(
        util.gpa,
        "{s}-{}-{}-{s}",
        .{
            @tagName(device.type),
            device.vendor,
            device.product,
            mem.trim(u8, mem.span(device.name), &ascii.spaces),
        },
    );
    for (identifier) |*char| {
        if (char.* == ' ' or !ascii.isPrint(char.*)) {
            char.* = '_';
        }
    }
    self.* = .{
        .device = device,
        .identifier = identifier,
    };
    log.debug("new input device: {s}", .{self.identifier});
    device.events.destroy.add(&self.destroy);
}

pub fn deinit(self: *InputDevice) void {
    util.gpa.free(self.identifier);
    self.destroy.link.remove();
}

fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    const self = @fieldParentPtr(InputDevice, "destroy", listener);
    log.debug("removed input device: {s}", .{self.identifier});
    self.deinit();

    const node = @fieldParentPtr(std.TailQueue(InputDevice).Node, "data", self);
    server.input_manager.input_devices.remove(node);
    util.gpa.destroy(node);
}
