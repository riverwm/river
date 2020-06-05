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

const Error = @import("../command.zig").Error;
const Mapping = @import("../Mapping.zig");
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
    failure_message: *[]const u8,
) Error!void {
    if (args.len < 4) return Error.NotEnoughArguments;

    // Parse the mode
    const config = seat.input_manager.server.config;
    const target_mode = args[1];
    const mode_id = config.mode_to_id.getValue(target_mode) orelse {
        failure_message.* = try std.fmt.allocPrint(
            allocator,
            "cannot add mapping to non-existant mode '{}p'",
            .{target_mode},
        );
        return Error.CommandFailed;
    };

    // Parse the modifiers
    var it = std.mem.split(args[2], "+");
    var modifiers: u32 = 0;
    while (it.next()) |mod_name| {
        for (modifier_names) |def| {
            if (std.mem.eql(u8, def.name, mod_name)) {
                modifiers |= def.modifier;
                break;
            }
        } else {
            failure_message.* = try std.fmt.allocPrint(
                allocator,
                "invalid modifier '{}'",
                .{mod_name},
            );
            return Error.CommandFailed;
        }
    }

    // Parse the keysym
    const keysym_name = try std.cstr.addNullByte(allocator, args[3]);
    defer allocator.free(keysym_name);
    const keysym = c.xkb_keysym_from_name(keysym_name, .XKB_KEYSYM_CASE_INSENSITIVE);
    if (keysym == c.XKB_KEY_NoSymbol) {
        failure_message.* = try std.fmt.allocPrint(
            allocator,
            "invalid keysym '{}'",
            .{args[3]},
        );
        return Error.CommandFailed;
    }

    // Check if the mapping already exists
    const mode_mappings = &config.modes.items[mode_id];
    for (mode_mappings.items) |existant_mapping| {
        if (existant_mapping.modifiers == modifiers and existant_mapping.keysym == keysym) {
            failure_message.* = try std.fmt.allocPrint(
                allocator,
                "a mapping for modifiers '{}' and keysym '{}' already exists",
                .{ args[2], args[3] },
            );
            return Error.CommandFailed;
        }
    }

    try mode_mappings.append(try Mapping.init(allocator, keysym, modifiers, args[4..]));
}
