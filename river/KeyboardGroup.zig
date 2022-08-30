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
const heap = std.heap;
const mem = std.mem;
const debug = std.debug;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");

const log = std.log.scoped(.keyboard_group);

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");
const Keyboard = @import("Keyboard.zig");

seat: *Seat,
group: *wlr.KeyboardGroup,
name: []const u8,
keyboard_identifiers: std.ArrayListUnmanaged([]const u8) = .{},

pub fn init(self: *Self, seat: *Seat, _name: []const u8) !void {
    log.debug("new keyboard group: '{s}'", .{_name});

    const group = try wlr.KeyboardGroup.create();
    errdefer group.destroy();
    group.data = @ptrToInt(self);

    const name = try util.gpa.dupe(u8, _name);
    errdefer util.gpa.free(name);

    self.* = .{
        .group = group,
        .name = name,
        .seat = seat,
    };

    seat.addDevice(self.group.input_device);
    seat.wlr_seat.setKeyboard(self.group.input_device);
}

pub fn deinit(self: *Self) void {
    log.debug("removing keyboard group: '{s}'", .{self.name});

    util.gpa.free(self.name);
    for (self.keyboard_identifiers.items) |id| util.gpa.free(id);
    self.keyboard_identifiers.deinit(util.gpa);

    // wlroots automatically removes all keyboards from the group.
    self.group.destroy();
}

pub fn addKeyboardIdentifier(self: *Self, _id: []const u8) !void {
    if (containsIdentifier(self, _id)) return;
    log.debug("keyboard group '{s}' adding identifier: '{s}'", .{ self.name, _id });

    const id = try util.gpa.dupe(u8, _id);
    errdefer util.gpa.free(id);
    try self.keyboard_identifiers.append(util.gpa, id);

    // Add any existing matching keyboard to group.
    var it = server.input_manager.devices.iterator(.forward);
    while (it.next()) |device| {
        if (device.seat != self.seat) continue;
        if (device.wlr_device.type != .keyboard) continue;

        if (mem.eql(u8, _id, device.identifier)) {
            log.debug("found existing matching keyboard; adding to group", .{});

            const wlr_keyboard = device.wlr_device.device.keyboard;
            if (!self.group.addKeyboard(wlr_keyboard)) continue; // wlroots logs its own errors.
        }

        // Continue, because we may have more than one device with the exact
        // same identifier. That is in fact the reason for the keyboard group
        // feature to exist in the first place.
    }
}

pub fn containsIdentifier(self: *Self, id: []const u8) bool {
    for (self.keyboard_identifiers.items) |ki| {
        if (mem.eql(u8, ki, id)) return true;
    }
    return false;
}

pub fn addKeyboard(self: *Self, keyboard: *Keyboard) !void {
    debug.assert(keyboard.provider != .group);
    const wlr_keyboard = keyboard.provider.device.wlr_device.device.keyboard;
    log.debug("keyboard group '{s}' adding keyboard: '{s}'", .{ self.name, keyboard.provider.device.identifier });
    if (!self.group.addKeyboard(wlr_keyboard)) {
        log.err("failed to add keyboard to group", .{});
        return error.OutOfMemory;
    }
}
