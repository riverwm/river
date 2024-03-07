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

const globber = @import("globber");
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
globs: std.ArrayListUnmanaged([]const u8) = .{},

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

    seat.addDevice(&wlr_group.keyboard.base);
    seat.keyboard_groups.append(node);
}

pub fn destroy(group: *KeyboardGroup) void {
    log.debug("destroying keyboard group: '{s}'", .{group.name});

    util.gpa.free(group.name);

    for (group.globs.items) |glob| {
        util.gpa.free(glob);
    }
    group.globs.deinit(util.gpa);

    group.wlr_group.destroy();

    const node: *std.TailQueue(KeyboardGroup).Node = @fieldParentPtr("data", group);
    group.seat.keyboard_groups.remove(node);
    util.gpa.destroy(node);
}

pub fn addIdentifier(group: *KeyboardGroup, new_id: []const u8) !void {
    for (group.globs.items) |glob| {
        if (mem.eql(u8, glob, new_id)) return;
    }

    log.debug("keyboard group '{s}' adding identifier: '{s}'", .{ group.name, new_id });

    const owned_id = try util.gpa.dupe(u8, new_id);
    errdefer util.gpa.free(owned_id);

    // Glob is validated in the command handler.
    try group.globs.append(util.gpa, owned_id);
    errdefer {
        // Not used now, but if at any point this function is modified to that
        // it may return an error after the glob pattern is added to the list,
        // the list will have a pointer to freed memory in its last position.
        _ = group.globs.pop();
    }

    // Add any existing matching keyboards to the group.
    var it = server.input_manager.devices.iterator(.forward);
    while (it.next()) |device| {
        if (device.seat != group.seat) continue;
        if (device.wlr_device.type != .keyboard) continue;

        if (globber.match(device.identifier, new_id)) {
            log.debug("found existing matching keyboard; adding to group", .{});

            if (!group.wlr_group.addKeyboard(device.wlr_device.toKeyboard())) {
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
    for (group.globs.items, 0..) |glob, index| {
        if (mem.eql(u8, glob, id)) {
            _ = group.globs.orderedRemove(index);
            break;
        }
    } else {
        return;
    }

    var it = server.input_manager.devices.iterator(.forward);
    while (it.next()) |device| {
        if (device.seat != group.seat) continue;
        if (device.wlr_device.type != .keyboard) continue;

        if (globber.match(device.identifier, id)) {
            const wlr_keyboard = device.wlr_device.toKeyboard();
            assert(wlr_keyboard.group == group.wlr_group);
            group.wlr_group.removeKeyboard(wlr_keyboard);
        }
    }
}
