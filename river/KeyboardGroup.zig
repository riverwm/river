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

const KeyboardGroup = @This();

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");

const log = std.log.scoped(.keyboard_group);

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");
const Keyboard = @import("Keyboard.zig");

seat: *Seat,
wlr_group: *wlr.KeyboardGroup,
name: []const u8,
identifiers: std.StringHashMapUnmanaged(void) = .{},

pub fn create(seat: *Seat, name: []const u8) !void {
    log.debug("new keyboard group: '{s}'", .{name});

    const node = try util.gpa.create(std.TailQueue(KeyboardGroup).Node);
    errdefer util.gpa.destroy(node);

    const wlr_group = try wlr.KeyboardGroup.create();
    errdefer wlr_group.destroy();

    const owned_name = try util.gpa.dupe(u8, name);
    errdefer util.gpa.free(owned_name);

    node.data = .{
        .wlr_group = wlr_group,
        .name = owned_name,
        .seat = seat,
    };

    seat.addDevice(wlr_group.input_device);
    seat.keyboard_groups.append(node);
}

pub fn destroy(group: *KeyboardGroup) void {
    log.debug("destroying keyboard group: '{s}'", .{group.name});

    util.gpa.free(group.name);
    {
        var it = group.identifiers.keyIterator();
        while (it.next()) |id| util.gpa.free(id.*);
    }
    group.identifiers.deinit(util.gpa);

    group.wlr_group.destroy();

    const node = @fieldParentPtr(std.TailQueue(KeyboardGroup).Node, "data", group);
    group.seat.keyboard_groups.remove(node);
    util.gpa.destroy(node);
}

pub fn addIdentifier(group: *KeyboardGroup, new_id: []const u8) !void {
    if (group.identifiers.contains(new_id)) return;

    log.debug("keyboard group '{s}' adding identifier: '{s}'", .{ group.name, new_id });

    const owned_id = try util.gpa.dupe(u8, new_id);
    errdefer util.gpa.free(owned_id);

    try group.identifiers.put(util.gpa, owned_id, {});

    // Add any existing matching keyboards to the group.
    var it = server.input_manager.devices.iterator(.forward);
    while (it.next()) |device| {
        if (device.seat != group.seat) continue;
        if (device.wlr_device.type != .keyboard) continue;

        if (mem.eql(u8, new_id, device.identifier)) {
            log.debug("found existing matching keyboard; adding to group", .{});

            const wlr_keyboard = device.wlr_device.device.keyboard;
            if (!group.wlr_group.addKeyboard(wlr_keyboard)) {
                // wlroots logs an error message to explain why this failed.
                continue;
            }
        }

        // Continue, because we may have more than one device with the exact
        // same identifier. That is in fact one reason for the keyboard group
        // feature to exist in the first place.
    }
}

pub fn removeIdentifier(group: *KeyboardGroup, id: []const u8) !void {
    if (group.identifiers.fetchRemove(id)) |kv| {
        util.gpa.free(kv.key);
    }

    var it = server.input_manager.devices.iterator(.forward);
    while (it.next()) |device| {
        if (device.seat != group.seat) continue;
        if (device.wlr_device.type != .keyboard) continue;

        if (mem.eql(u8, device.identifier, id)) {
            const wlr_keyboard = device.wlr_device.device.keyboard;
            assert(wlr_keyboard.group == group.wlr_group);
            group.wlr_group.removeKeyboard(wlr_keyboard);
        }
    }
}
