// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
// Copyright 2020 Marten Ringwelski
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
    .{ .name = "None", .modifier = 0 },
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
/// map normal Mod4+Shift Return spawn foot
pub fn map(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    const optionals = parseOptionalArgs(args[1..]);
    // offset caused by optional arguments
    const offset = optionals.i;
    if (args.len - offset < 5) return Error.NotEnoughArguments;

    const mode_id = try modeNameToId(allocator, seat, args[1 + offset], out);
    const modifiers = try parseModifiers(allocator, args[2 + offset], out);
    const keysym = try parseKeysym(allocator, args[3 + offset], out);

    const mode_mappings = &seat.input_manager.server.config.modes.items[mode_id].mappings;

    if (mappingExists(mode_mappings, modifiers, keysym, optionals.release)) |_| {
        out.* = try std.fmt.allocPrint(
            allocator,
            "a mapping for modifiers '{}' and keysym '{}' already exists",
            .{ args[2 + offset], args[3 + offset] },
        );
        return Error.Other;
    }

    try mode_mappings.append(try Mapping.init(keysym, modifiers, optionals.release, args[4 + offset ..]));
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
    const event_code = try parseEventCode(allocator, args[3], out);

    const mode_pointer_mappings = &seat.input_manager.server.config.modes.items[mode_id].pointer_mappings;
    if (pointerMappingExists(mode_pointer_mappings, modifiers, event_code)) |_| {
        out.* = try std.fmt.allocPrint(
            allocator,
            "a pointer mapping for modifiers '{}' and button '{}' already exists",
            .{ args[2], args[3] },
        );
        return Error.Other;
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
    return config.mode_to_id.get(mode_name) orelse {
        out.* = try std.fmt.allocPrint(
            allocator,
            "cannot add/remove mapping to/from non-existant mode '{}'",
            .{mode_name},
        );
        return Error.Other;
    };
}

/// Returns the index of the Mapping with matching modifiers, keysym and release, if any.
fn mappingExists(mappings: *std.ArrayList(Mapping), modifiers: u32, keysym: u32, release: bool) ?usize {
    for (mappings.items) |mapping, i| {
        if (mapping.modifiers == modifiers and mapping.keysym == keysym and mapping.release == release) {
            return i;
        }
    }

    return null;
}

/// Returns the index of the PointerMapping with matching modifiers and event code, if any.
fn pointerMappingExists(pointer_mappings: *std.ArrayList(PointerMapping), modifiers: u32, event_code: u32) ?usize {
    for (pointer_mappings.items) |mapping, i| {
        if (mapping.modifiers == modifiers and mapping.event_code == event_code) {
            return i;
        }
    }

    return null;
}

fn parseEventCode(allocator: *std.mem.Allocator, event_code_str: []const u8, out: *?[]const u8) !u32 {
    const event_code_name = try std.cstr.addNullByte(allocator, event_code_str);
    defer allocator.free(event_code_name);
    const ret = c.libevdev_event_code_from_name(c.EV_KEY, event_code_name);
    if (ret < 1) {
        out.* = try std.fmt.allocPrint(allocator, "unknown button {}", .{event_code_str});
        return Error.Other;
    }

    return @intCast(u32, ret);
}

fn parseKeysym(allocator: *std.mem.Allocator, keysym_str: []const u8, out: *?[]const u8) !u32 {
    const keysym_name = try std.cstr.addNullByte(allocator, keysym_str);
    defer allocator.free(keysym_name);
    const keysym = c.xkb_keysym_from_name(keysym_name, .XKB_KEYSYM_CASE_INSENSITIVE);
    if (keysym == c.XKB_KEY_NoSymbol) {
        out.* = try std.fmt.allocPrint(
            allocator,
            "invalid keysym '{}'",
            .{keysym_str},
        );
        return Error.Other;
    }

    return keysym;
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

const OptionalArgsContainer = struct {
    i: usize,
    release: bool,
};

/// Parses optional args (such as -release) and return the index of the first argument that is
/// not an optional argument
/// Returns an OptionalArgsContainer with the settings set according to the args
/// Errors cant occur because it returns as soon as it gets an unknown argument
fn parseOptionalArgs(args: []const []const u8) OptionalArgsContainer {
    // Set to defaults
    var parsed = OptionalArgsContainer{
        // i is the number of arguments consumed
        .i = 0,
        .release = false,
    };

    var i: usize = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-release")) {
            parsed.release = true;
            i += 1;
        } else {
            // Break if the arg is not an option
            parsed.i = i;
            break;
        }
    }

    return parsed;
}

/// Remove a mapping from a given mode
///
/// Example:
/// unmap normal Mod4+Shift Return
pub fn unmap(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    const optionals = parseOptionalArgs(args[1..]);
    // offset caused by optional arguments
    const offset = optionals.i;
    if (args.len - offset < 4) return Error.NotEnoughArguments;

    const mode_id = try modeNameToId(allocator, seat, args[1 + offset], out);
    const modifiers = try parseModifiers(allocator, args[2 + offset], out);
    const keysym = try parseKeysym(allocator, args[3 + offset], out);

    const mode_mappings = &seat.input_manager.server.config.modes.items[mode_id].mappings;
    const mapping_idx = mappingExists(mode_mappings, modifiers, keysym, optionals.release) orelse {
        out.* = try std.fmt.allocPrint(
            allocator,
            "there is no mapping for modifiers '{}' and keysym '{}'",
            .{ args[2 + offset], args[3 + offset] },
        );
        return Error.Other;
    };

    var mapping = mode_mappings.swapRemove(mapping_idx);
    mapping.deinit();
}

/// Remove a pointer mapping for a given mode
///
/// Example:
/// unmap-pointer normal Mod4 BTN_LEFT
pub fn unmapPointer(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 4) return Error.NotEnoughArguments;
    if (args.len > 4) return Error.TooManyArguments;

    const mode_id = try modeNameToId(allocator, seat, args[1], out);
    const modifiers = try parseModifiers(allocator, args[2], out);
    const event_code = try parseEventCode(allocator, args[3], out);

    const mode_pointer_mappings = &seat.input_manager.server.config.modes.items[mode_id].pointer_mappings;
    const mapping_idx = pointerMappingExists(mode_pointer_mappings, modifiers, event_code) orelse {
        out.* = try std.fmt.allocPrint(
            allocator,
            "there is no mapping for modifiers '{}' and button '{}'",
            .{ args[2], args[3] },
        );
        return Error.Other;
    };

    _ = mode_pointer_mappings.swapRemove(mapping_idx);
}
