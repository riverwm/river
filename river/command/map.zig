// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const c = @import("../c.zig");
const util = @import("../util.zig");

const Error = @import("../command.zig").Error;
const Mapping = @import("../Mapping.zig");
const PointerMapping = @import("../PointerMapping.zig");
const Seat = @import("../Seat.zig");

const modifier_names = [_]struct {
    name: []const u8,
    modifier: u32,
}{
    .{ .name = "", .modifier = 0 },
    .{ .name = "Shift", .modifier = c.WLR_MODIFIER_SHIFT },
    .{ .name = "Lock", .modifier = c.WLR_MODIFIER_CAPS },
    .{ .name = "Control", .modifier = c.WLR_MODIFIER_CTRL },
    .{ .name = "Mod1", .modifier = c.WLR_MODIFIER_ALT },
    .{ .name = "Mod2", .modifier = c.WLR_MODIFIER_MOD2 },
    .{ .name = "Mod3", .modifier = c.WLR_MODIFIER_MOD3 },
    .{ .name = "Mod4", .modifier = c.WLR_MODIFIER_LOGO },
    .{ .name = "Mod5", .modifier = c.WLR_MODIFIER_MOD5 },
};

/// Create a new mapping for a given mode
///
/// Example:
/// map normal Mod4+Shift Return spawn alacritty
pub fn map(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 5) return Error.NotEnoughArguments;

    const mode_id = try modeNameToId(allocator, seat, args[1], out);
    const modifiers = try parseModifiers(allocator, args[2], out);

    // Parse the keysym
    const keysym_name = try std.cstr.addNullByte(allocator, args[3]);
    defer allocator.free(keysym_name);
    const keysym = c.xkb_keysym_from_name(keysym_name, .XKB_KEYSYM_CASE_INSENSITIVE);
    if (keysym == c.XKB_KEY_NoSymbol) {
        out.* = try std.fmt.allocPrint(
            allocator,
            "invalid keysym '{}'",
            .{args[3]},
        );
        return Error.Other;
    }

    // Check if the mapping already exists
    const mode_mappings = &seat.input_manager.server.config.modes.items[mode_id].mappings;
    for (mode_mappings.items) |existant_mapping| {
        if (existant_mapping.modifiers == modifiers and existant_mapping.keysym == keysym) {
            out.* = try std.fmt.allocPrint(
                allocator,
                "a mapping for modifiers '{}' and keysym '{}' already exists",
                .{ args[2], args[3] },
            );
            return Error.Other;
        }
    }

    try mode_mappings.append(try Mapping.init(util.gpa, keysym, modifiers, args[4..]));
}

/// Create a new pointer mapping for a given mode
///
/// Example:
/// map-pointer normal Mod4 BTN_LEFT move-view
pub fn mapPointer(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 5) return Error.NotEnoughArguments;
    if (args.len > 5) return Error.TooManyArguments;

    const mode_id = try modeNameToId(allocator, seat, args[1], out);
    const modifiers = try parseModifiers(allocator, args[2], out);

    const event_code = blk: {
        const event_code_name = try std.cstr.addNullByte(allocator, args[3]);
        defer allocator.free(event_code_name);
        const ret = c.libevdev_event_code_from_name(c.EV_KEY, event_code_name);
        if (ret < 1) {
            out.* = try std.fmt.allocPrint(allocator, "unknown button {}", .{args[3]});
            return Error.Other;
        }
        break :blk @intCast(u32, ret);
    };

    // Check if the mapping already exists
    const mode_pointer_mappings = &seat.input_manager.server.config.modes.items[mode_id].pointer_mappings;
    for (mode_pointer_mappings.items) |existing| {
        if (existing.event_code == event_code and existing.modifiers == modifiers) {
            out.* = try std.fmt.allocPrint(
                allocator,
                "a pointer mapping for modifiers '{}' and button '{}' already exists",
                .{ args[2], args[3] },
            );
            return Error.Other;
        }
    }

    const action = if (std.mem.eql(u8, args[4], "move-view"))
        PointerMapping.Action.move
    else if (std.mem.eql(u8, args[4], "resize-view"))
        PointerMapping.Action.resize
    else {
        out.* = try std.fmt.allocPrint(
            allocator,
            "invalid pointer action {}, must be move-view or resize-view",
            .{args[4]},
        );
        return Error.Other;
    };

    try mode_pointer_mappings.append(.{
        .event_code = event_code,
        .modifiers = modifiers,
        .action = action,
    });
}

fn modeNameToId(allocator: *std.mem.Allocator, seat: *Seat, mode_name: []const u8, out: *?[]const u8) !usize {
    const config = seat.input_manager.server.config;
    return config.mode_to_id.getValue(mode_name) orelse {
        out.* = try std.fmt.allocPrint(
            allocator,
            "cannot add mapping to non-existant mode '{}p'",
            .{mode_name},
        );
        return Error.Other;
    };
}

fn parseModifiers(allocator: *std.mem.Allocator, modifiers_str: []const u8, out: *?[]const u8) !u32 {
    var it = std.mem.split(modifiers_str, "+");
    var modifiers: u32 = 0;
    while (it.next()) |mod_name| {
        for (modifier_names) |def| {
            if (std.mem.eql(u8, def.name, mod_name)) {
                modifiers |= def.modifier;
                break;
            }
        } else {
            out.* = try std.fmt.allocPrint(
                allocator,
                "invalid modifier '{}'",
                .{mod_name},
            );
            return Error.Other;
        }
    }
    return modifiers;
}
