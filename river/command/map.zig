// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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
const mem = std.mem;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const c = @import("../c.zig");
const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Error = @import("../command.zig").Error;
const Mapping = @import("../Mapping.zig");
const PointerMapping = @import("../PointerMapping.zig");
const Seat = @import("../Seat.zig");

/// Create a new mapping for a given mode
///
/// Example:
/// map normal Mod4+Shift Return spawn foot
pub fn map(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    const optionals = parseOptionalArgs(args[1..]);
    // offset caused by optional arguments
    const offset = optionals.i;
    if (args.len - offset < 5) return Error.NotEnoughArguments;

    if (optionals.release and optionals.repeat) return Error.ConflictingOptions;

    const mode_id = try modeNameToId(allocator, seat, args[1 + offset], out);
    const modifiers = try parseModifiers(allocator, args[2 + offset], out);
    const keysym = try parseKeysym(allocator, args[3 + offset], out);

    const mode_mappings = &server.config.modes.items[mode_id].mappings;

    const new = try Mapping.init(keysym, modifiers, optionals.release, optionals.repeat, args[4 + offset ..]);
    errdefer new.deinit();

    if (mappingExists(mode_mappings, modifiers, keysym, optionals.release)) |current| {
        mode_mappings.items[current].deinit();
        mode_mappings.items[current] = new;
    } else {
        try mode_mappings.append(new);
    }
}

/// Create a new pointer mapping for a given mode
///
/// Example:
/// map-pointer normal Mod4 BTN_LEFT move-view
pub fn mapPointer(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 5) return Error.NotEnoughArguments;
    if (args.len > 5) return Error.TooManyArguments;

    const mode_id = try modeNameToId(allocator, seat, args[1], out);
    const modifiers = try parseModifiers(allocator, args[2], out);
    const event_code = try parseEventCode(allocator, args[3], out);

    const action = if (std.mem.eql(u8, args[4], "move-view"))
        PointerMapping.Action.move
    else if (std.mem.eql(u8, args[4], "resize-view"))
        PointerMapping.Action.resize
    else {
        out.* = try std.fmt.allocPrint(
            allocator,
            "invalid pointer action {s}, must be move-view or resize-view",
            .{args[4]},
        );
        return Error.Other;
    };

    const new = PointerMapping{
        .event_code = event_code,
        .modifiers = modifiers,
        .action = action,
    };

    const mode_pointer_mappings = &server.config.modes.items[mode_id].pointer_mappings;
    if (pointerMappingExists(mode_pointer_mappings, modifiers, event_code)) |current| {
        mode_pointer_mappings.items[current] = new;
    } else {
        try mode_pointer_mappings.append(new);
    }
}

fn modeNameToId(allocator: *std.mem.Allocator, seat: *Seat, mode_name: []const u8, out: *?[]const u8) !usize {
    const config = &server.config;
    return config.mode_to_id.get(mode_name) orelse {
        out.* = try std.fmt.allocPrint(
            allocator,
            "cannot add/remove mapping to/from non-existant mode '{s}'",
            .{mode_name},
        );
        return Error.Other;
    };
}

/// Returns the index of the Mapping with matching modifiers, keysym and release, if any.
fn mappingExists(
    mappings: *std.ArrayList(Mapping),
    modifiers: wlr.Keyboard.ModifierMask,
    keysym: xkb.Keysym,
    release: bool,
) ?usize {
    for (mappings.items) |mapping, i| {
        if (std.meta.eql(mapping.modifiers, modifiers) and mapping.keysym == keysym and mapping.release == release) {
            return i;
        }
    }

    return null;
}

/// Returns the index of the PointerMapping with matching modifiers and event code, if any.
fn pointerMappingExists(
    pointer_mappings: *std.ArrayList(PointerMapping),
    modifiers: wlr.Keyboard.ModifierMask,
    event_code: u32,
) ?usize {
    for (pointer_mappings.items) |mapping, i| {
        if (std.meta.eql(mapping.modifiers, modifiers) and mapping.event_code == event_code) {
            return i;
        }
    }

    return null;
}

fn parseEventCode(allocator: *std.mem.Allocator, name: [:0]const u8, out: *?[]const u8) !u32 {
    const event_code = c.libevdev_event_code_from_name(c.EV_KEY, name);
    if (event_code < 1) {
        out.* = try std.fmt.allocPrint(allocator, "unknown button {s}", .{name});
        return Error.Other;
    }

    return @intCast(u32, event_code);
}

fn parseKeysym(allocator: *std.mem.Allocator, name: [:0]const u8, out: *?[]const u8) !xkb.Keysym {
    const keysym = xkb.Keysym.fromName(name, .case_insensitive);
    if (keysym == .NoSymbol) {
        out.* = try std.fmt.allocPrint(allocator, "invalid keysym '{s}'", .{name});
        return Error.Other;
    }
    return keysym;
}

fn parseModifiers(
    allocator: *std.mem.Allocator,
    modifiers_str: []const u8,
    out: *?[]const u8,
) !wlr.Keyboard.ModifierMask {
    var it = std.mem.split(modifiers_str, "+");
    var modifiers = wlr.Keyboard.ModifierMask{};
    outer: while (it.next()) |mod_name| {
        if (mem.eql(u8, mod_name, "None")) continue;
        inline for ([_]struct { name: []const u8, field_name: []const u8 }{
            .{ .name = "Shift", .field_name = "shift" },
            .{ .name = "Lock", .field_name = "caps" },
            .{ .name = "Control", .field_name = "ctrl" },
            .{ .name = "Mod1", .field_name = "alt" },
            .{ .name = "Mod2", .field_name = "mod2" },
            .{ .name = "Mod3", .field_name = "mod3" },
            .{ .name = "Mod4", .field_name = "logo" },
            .{ .name = "Mod5", .field_name = "mod5" },
        }) |def| {
            if (std.mem.eql(u8, def.name, mod_name)) {
                @field(modifiers, def.field_name) = true;
                continue :outer;
            }
        }
        out.* = try std.fmt.allocPrint(allocator, "invalid modifier '{s}'", .{mod_name});
        return Error.Other;
    }
    return modifiers;
}

const OptionalArgsContainer = struct {
    i: usize,
    release: bool,
    repeat: bool,
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
        .repeat = false,
    };

    var i: usize = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-release")) {
            parsed.release = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "-repeat")) {
            parsed.repeat = true;
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
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    const optionals = parseOptionalArgs(args[1..]);
    // offset caused by optional arguments
    const offset = optionals.i;
    if (args.len - offset < 4) return Error.NotEnoughArguments;

    const mode_id = try modeNameToId(allocator, seat, args[1 + offset], out);
    const modifiers = try parseModifiers(allocator, args[2 + offset], out);
    const keysym = try parseKeysym(allocator, args[3 + offset], out);

    const mode_mappings = &server.config.modes.items[mode_id].mappings;
    const mapping_idx = mappingExists(mode_mappings, modifiers, keysym, optionals.release) orelse return;

    // Repeating mappings borrow the args from Mapping directly. To prevent a crash in the
    // unlikely case of a repeating mapping unmapping itself, clear any current repeat.
    seat.clearRepeatingMapping();

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
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 4) return Error.NotEnoughArguments;
    if (args.len > 4) return Error.TooManyArguments;

    const mode_id = try modeNameToId(allocator, seat, args[1], out);
    const modifiers = try parseModifiers(allocator, args[2], out);
    const event_code = try parseEventCode(allocator, args[3], out);

    const mode_pointer_mappings = &server.config.modes.items[mode_id].pointer_mappings;
    const mapping_idx = pointerMappingExists(mode_pointer_mappings, modifiers, event_code) orelse return;

    _ = mode_pointer_mappings.swapRemove(mapping_idx);
}
