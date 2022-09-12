// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const c = @import("../c.zig");
const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Error = @import("../command.zig").Error;
const Mapping = @import("../Mapping.zig");
const ButtonMapping = @import("../ButtonMapping.zig");
const PointerMapping = @import("../PointerMapping.zig");
const SwitchMapping = @import("../SwitchMapping.zig");
const Switch = @import("../Switch.zig");
const Seat = @import("../Seat.zig");

/// Create a new mapping for a given mode
///
/// Example:
/// map normal Mod4+Shift Return spawn foot
pub fn map(
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    const optionals = try parseOptionalArgs(args[1..]);
    // offset caused by optional arguments
    const offset = optionals.i;
    if (args.len - offset < 5) return Error.NotEnoughArguments;

    if (optionals.release and optionals.repeat) return Error.ConflictingOptions;

    const mode_raw = args[1 + offset];
    const modifiers_raw = args[2 + offset];
    const keysym_raw = args[3 + offset];

    const mode_id = try modeNameToId(mode_raw, out);
    const modifiers = try parseModifiers(modifiers_raw, out);
    const keysym = try parseKeysym(keysym_raw, out);

    const mode_mappings = &server.config.modes.items[mode_id].mappings;

    const new = try Mapping.init(
        keysym,
        modifiers,
        optionals.release,
        optionals.repeat,
        optionals.layout_index,
        args[4 + offset ..],
    );
    errdefer new.deinit();

    if (mappingExists(mode_mappings, modifiers, keysym, optionals.release)) |current| {
        mode_mappings.items[current].deinit();
        mode_mappings.items[current] = new;
        // Warn user if they overwrote an existing keybinding using riverctl.
        const opts = if (optionals.release) "-release " else "";
        out.* = try fmt.allocPrint(
            util.gpa,
            "overwrote an existing keybinding: {s} {s}{s} {s}",
            .{ mode_raw, opts, modifiers_raw, keysym_raw },
        );
    } else {
        // Repeating mappings borrow the Mapping directly. To prevent a
        // possible crash if the Mapping ArrayList is reallocated, stop any
        // currently repeating mappings.
        seat.clearRepeatingMapping();
        try mode_mappings.append(util.gpa, new);
    }
}

/// Create a new button mapping for a given mode
///
/// Example:
/// map-button normal Mod4 BTN_MIDDLE toggle-float
pub fn mapButton(
    // seat: *Seat,
    _: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    const optionals = try parseOptionalArgs(args[1..]);
    // offset caused by optional arguments
    const offset = optionals.i;
    if (args.len - offset < 5) return Error.NotEnoughArguments;

    if (optionals.release and optionals.repeat) return Error.ConflictingOptions;

    const mode_raw = args[1 + offset];
    const modifiers_raw = args[2 + offset];
    const event_code_raw = args[3 + offset];

    const mode_id = try modeNameToId(mode_raw, out);
    const modifiers = try parseModifiers(modifiers_raw, out);
    const event_code = try parseEventCode(event_code_raw, out);

    const mode_mappings = &server.config.modes.items[mode_id].button_mappings;

    const new = try ButtonMapping.init(
        event_code,
        modifiers,
        optionals.release,
        args[4 + offset ..],
    );
    errdefer new.deinit();

    if (buttonMappingExists(mode_mappings, modifiers, event_code, optionals.release)) |current| {
        mode_mappings.items[current].deinit();
        mode_mappings.items[current] = new;
        // Warn user if they overwrote an existing button mapping using riverctl.
        const opts = if (optionals.release) "-release " else "";
        out.* = try fmt.allocPrint(
            util.gpa,
            "overwrote an existing button mapping: {s} {s}{s} {s}",
            .{ mode_raw, opts, modifiers_raw, event_code_raw },
        );
    } else {
        try mode_mappings.append(util.gpa, new);
    }
}

/// Create a new switch mapping for a given mode
///
/// Example:
/// map-switch normal lid close spawn "wlr-randr --output eDP-1 --off"
pub fn mapSwitch(
    _: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 5) return Error.NotEnoughArguments;

    const mode_id = try modeNameToId(args[1], out);
    const switch_type = try parseSwitchType(args[2], out);
    const switch_state = try parseSwitchState(switch_type, args[3], out);

    const new = try SwitchMapping.init(switch_type, switch_state, args[4..]);
    errdefer new.deinit();

    const mode_mappings = &server.config.modes.items[mode_id].switch_mappings;

    if (switchMappingExists(mode_mappings, switch_type, switch_state)) |current| {
        mode_mappings.items[current].deinit();
        mode_mappings.items[current] = new;
        // Warn user if they overwrote an existing keybinding using riverctl.
        out.* = try std.fmt.allocPrint(
            util.gpa,
            "overwrote an existing keybinding: map-switch {s} {s} {s}",
            .{ args[1], args[2], args[3] },
        );
    } else {
        try mode_mappings.append(util.gpa, new);
    }
}

/// Create a new pointer mapping for a given mode
///
/// Example:
/// map-pointer normal Mod4 BTN_LEFT move-view
pub fn mapPointer(
    _: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 5) return Error.NotEnoughArguments;
    if (args.len > 5) return Error.TooManyArguments;

    const mode_id = try modeNameToId(args[1], out);
    const modifiers = try parseModifiers(args[2], out);
    const event_code = try parseEventCode(args[3], out);

    const action = if (mem.eql(u8, args[4], "move-view"))
        PointerMapping.Action.move
    else if (mem.eql(u8, args[4], "resize-view"))
        PointerMapping.Action.resize
    else {
        out.* = try fmt.allocPrint(
            util.gpa,
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
        try mode_pointer_mappings.append(util.gpa, new);
    }
}

fn modeNameToId(mode_name: []const u8, out: *?[]const u8) !usize {
    const config = &server.config;
    return config.mode_to_id.get(mode_name) orelse {
        out.* = try fmt.allocPrint(
            util.gpa,
            "cannot add/remove mapping to/from non-existant mode '{s}'",
            .{mode_name},
        );
        return Error.Other;
    };
}

/// Returns the index of the Mapping with matching modifiers, keysym and release, if any.
fn mappingExists(
    mappings: *std.ArrayListUnmanaged(Mapping),
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

/// Returns the index of the ButtonMapping with matching modifiers, event code and release, if any.
fn buttonMappingExists(
    mappings: *std.ArrayListUnmanaged(ButtonMapping),
    modifiers: wlr.Keyboard.ModifierMask,
    event_code: u32,
    release: bool,
) ?usize {
    for (mappings.items) |mapping, i| {
        if (std.meta.eql(mapping.modifiers, modifiers) and mapping.event_code == event_code and mapping.release == release) {
            return i;
        }
    }

    return null;
}

/// Returns the index of the SwitchMapping with matching switch_type and switch_state, if any.
fn switchMappingExists(
    switch_mappings: *std.ArrayListUnmanaged(SwitchMapping),
    switch_type: Switch.Type,
    switch_state: Switch.State,
) ?usize {
    for (switch_mappings.items) |mapping, i| {
        if (mapping.switch_type == switch_type and std.meta.eql(mapping.switch_state, switch_state)) {
            return i;
        }
    }

    return null;
}

/// Returns the index of the PointerMapping with matching modifiers and event code, if any.
fn pointerMappingExists(
    pointer_mappings: *std.ArrayListUnmanaged(PointerMapping),
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

fn parseEventCode(name: [:0]const u8, out: *?[]const u8) !u32 {
    const event_code = c.libevdev_event_code_from_name(c.EV_KEY, name);
    if (event_code < 1) {
        out.* = try fmt.allocPrint(util.gpa, "unknown button {s}", .{name});
        return Error.Other;
    }

    return @intCast(u32, event_code);
}

fn parseKeysym(name: [:0]const u8, out: *?[]const u8) !xkb.Keysym {
    const keysym = xkb.Keysym.fromName(name, .case_insensitive);
    if (keysym == .NoSymbol) {
        out.* = try fmt.allocPrint(util.gpa, "invalid keysym '{s}'", .{name});
        return Error.Other;
    }
    return keysym;
}

fn parseModifiers(modifiers_str: []const u8, out: *?[]const u8) !wlr.Keyboard.ModifierMask {
    var it = mem.split(u8, modifiers_str, "+");
    var modifiers = wlr.Keyboard.ModifierMask{};
    outer: while (it.next()) |mod_name| {
        if (mem.eql(u8, mod_name, "None")) continue;
        inline for ([_]struct { name: []const u8, field_name: []const u8 }{
            .{ .name = "Shift", .field_name = "shift" },
            .{ .name = "Lock", .field_name = "caps" },
            .{ .name = "Control", .field_name = "ctrl" },
            .{ .name = "Mod1", .field_name = "alt" },
            .{ .name = "Alt", .field_name = "alt" },
            .{ .name = "Mod2", .field_name = "mod2" },
            .{ .name = "Mod3", .field_name = "mod3" },
            .{ .name = "Mod4", .field_name = "logo" },
            .{ .name = "Super", .field_name = "logo" },
            .{ .name = "Mod5", .field_name = "mod5" },
        }) |def| {
            if (mem.eql(u8, def.name, mod_name)) {
                @field(modifiers, def.field_name) = true;
                continue :outer;
            }
        }
        out.* = try fmt.allocPrint(util.gpa, "invalid modifier '{s}'", .{mod_name});
        return Error.Other;
    }
    return modifiers;
}

fn parseSwitchType(
    switch_type_str: []const u8,
    out: *?[]const u8,
) !Switch.Type {
    return std.meta.stringToEnum(Switch.Type, switch_type_str) orelse {
        out.* = try std.fmt.allocPrint(
            util.gpa,
            "invalid switch '{s}', must be 'lid' or 'tablet'",
            .{switch_type_str},
        );
        return Error.Other;
    };
}

fn parseSwitchState(
    switch_type: Switch.Type,
    switch_state_str: []const u8,
    out: *?[]const u8,
) !Switch.State {
    switch (switch_type) {
        .lid => {
            const lid_state = std.meta.stringToEnum(
                Switch.LidState,
                switch_state_str,
            ) orelse {
                out.* = try std.fmt.allocPrint(
                    util.gpa,
                    "invalid lid state '{s}', must be 'close' or 'open'",
                    .{switch_state_str},
                );
                return Error.Other;
            };
            return Switch.State{ .lid = lid_state };
        },
        .tablet => {
            const tablet_state = std.meta.stringToEnum(
                Switch.TabletState,
                switch_state_str,
            ) orelse {
                out.* = try std.fmt.allocPrint(
                    util.gpa,
                    "invalid tablet state '{s}', must be 'on' or 'off'",
                    .{switch_state_str},
                );
                return Error.Other;
            };
            return Switch.State{ .tablet = tablet_state };
        },
    }
}

const OptionalArgsContainer = struct {
    i: usize,
    release: bool,
    repeat: bool,
    layout_index: ?u32,
};

/// Parses optional args (such as -release) and return the index of the first argument that is
/// not an optional argument
/// Returns an OptionalArgsContainer with the settings set according to the args
fn parseOptionalArgs(args: []const []const u8) !OptionalArgsContainer {
    // Set to defaults
    var parsed = OptionalArgsContainer{
        // i is the number of arguments consumed
        .i = 0,
        .release = false,
        .repeat = false,
        .layout_index = null,
    };

    var j: usize = 0;
    while (j < args.len) : (j += 1) {
        if (mem.eql(u8, args[j], "-release")) {
            parsed.release = true;
            parsed.i += 1;
        } else if (mem.eql(u8, args[j], "-repeat")) {
            parsed.repeat = true;
            parsed.i += 1;
        } else if (mem.eql(u8, args[j], "-layout")) {
            j += 1;
            if (j == args.len) return Error.NotEnoughArguments;
            // To keep things simple here, we do not check if the layout index
            // is out of range. We rely on xkbcommon to handle this case:
            // xkbcommon will simply use the active layout instead, leaving
            // this option without effect
            parsed.layout_index = try std.fmt.parseInt(u32, args[j], 10);
            parsed.i += 2;
        } else {
            // Break if the arg is not an option
            break;
        }
    }

    return parsed;
}

/// Remove a mapping from a given mode
///
/// Example:
/// unmap normal Mod4+Shift Return
pub fn unmap(seat: *Seat, args: []const [:0]const u8, out: *?[]const u8) Error!void {
    const optionals = try parseOptionalArgs(args[1..]);
    // offset caused by optional arguments
    const offset = optionals.i;
    if (args.len - offset < 4) return Error.NotEnoughArguments;

    const mode_id = try modeNameToId(args[1 + offset], out);
    const modifiers = try parseModifiers(args[2 + offset], out);
    const keysym = try parseKeysym(args[3 + offset], out);

    const mode_mappings = &server.config.modes.items[mode_id].mappings;
    const mapping_idx = mappingExists(mode_mappings, modifiers, keysym, optionals.release) orelse return;

    // Repeating mappings borrow the Mapping directly. To prevent a possible
    // crash if the Mapping ArrayList is reallocated, stop any currently
    // repeating mappings.
    seat.clearRepeatingMapping();

    var mapping = mode_mappings.swapRemove(mapping_idx);
    mapping.deinit();
}

/// Remove a switch mapping from a given mode
///
/// Example:
/// unmap-switch normal tablet on
pub fn unmapSwitch(
    _: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 4) return Error.NotEnoughArguments;

    const mode_id = try modeNameToId(args[1], out);
    const switch_type = try parseSwitchType(args[2], out);
    const switch_state = try parseSwitchState(switch_type, args[3], out);

    const mode_mappings = &server.config.modes.items[mode_id].switch_mappings;
    const mapping_idx = switchMappingExists(mode_mappings, switch_type, switch_state) orelse return;

    var mapping = mode_mappings.swapRemove(mapping_idx);
    mapping.deinit();
}

/// Remove a pointer mapping for a given mode
///
/// Example:
/// unmap-pointer normal Mod4 BTN_LEFT
pub fn unmapPointer(_: *Seat, args: []const [:0]const u8, out: *?[]const u8) Error!void {
    if (args.len < 4) return Error.NotEnoughArguments;
    if (args.len > 4) return Error.TooManyArguments;

    const mode_id = try modeNameToId(args[1], out);
    const modifiers = try parseModifiers(args[2], out);
    const event_code = try parseEventCode(args[3], out);

    const mode_pointer_mappings = &server.config.modes.items[mode_id].pointer_mappings;
    const mapping_idx = pointerMappingExists(mode_pointer_mappings, modifiers, event_code) orelse return;

    _ = mode_pointer_mappings.swapRemove(mapping_idx);
}
