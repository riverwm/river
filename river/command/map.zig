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
const meta = std.meta;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const flags = @import("flags");

const c = @import("../c.zig");
const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Error = @import("../command.zig").Error;
const Mapping = @import("../Mapping.zig");
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
    const result = flags.parser([:0]const u8, &.{
        .{ .name = "release", .kind = .boolean },
        .{ .name = "repeat", .kind = .boolean },
        .{ .name = "layout", .kind = .arg },
    }).parse(args[1..]) catch {
        return error.InvalidValue;
    };
    if (result.args.len < 4) return Error.NotEnoughArguments;

    if (result.flags.release and result.flags.repeat) return Error.ConflictingOptions;

    const layout_index = blk: {
        if (result.flags.layout) |layout_raw| {
            break :blk try fmt.parseInt(u32, layout_raw, 10);
        } else {
            break :blk null;
        }
    };

    const mode_raw = result.args[0];
    const modifiers_raw = result.args[1];
    const keysym_raw = result.args[2];
    const command = result.args[3..];

    const mode_id = try modeNameToId(mode_raw, out);
    const modifiers = try parseModifiers(modifiers_raw, out);
    const keysym = try parseKeysym(keysym_raw, out);

    const mode_mappings = &server.config.modes.items[mode_id].mappings;

    const new = try Mapping.init(
        keysym,
        modifiers,
        command,
        .{
            .release = result.flags.release,
            .repeat = result.flags.repeat,
            .layout_index = layout_index,
        },
    );
    errdefer new.deinit();

    if (mappingExists(mode_mappings, modifiers, keysym, result.flags.release)) |current| {
        mode_mappings.items[current].deinit();
        mode_mappings.items[current] = new;
        // Warn user if they overwrote an existing keybinding using riverctl.
        const opts = if (result.flags.release) "-release " else "";
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

    const mode_id = try modeNameToId(args[1], out);
    const modifiers = try parseModifiers(args[2], out);
    const event_code = try parseEventCode(args[3], out);

    const action: meta.Tag(PointerMapping.Action) = blk: {
        if (mem.eql(u8, args[4], "move-view")) {
            break :blk .move;
        } else if (mem.eql(u8, args[4], "resize-view")) {
            break :blk .resize;
        } else {
            break :blk .command;
        }
    };

    if (action != .command and args.len > 5) return Error.TooManyArguments;

    var new = try PointerMapping.init(
        event_code,
        modifiers,
        action,
        args[4..],
    );
    errdefer new.deinit();

    const mode_pointer_mappings = &server.config.modes.items[mode_id].pointer_mappings;
    if (pointerMappingExists(mode_pointer_mappings, modifiers, event_code)) |current| {
        mode_pointer_mappings.items[current].deinit();
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
    for (mappings.items, 0..) |mapping, i| {
        if (meta.eql(mapping.modifiers, modifiers) and
            mapping.keysym == keysym and mapping.options.release == release)
        {
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
    for (switch_mappings.items, 0..) |mapping, i| {
        if (mapping.switch_type == switch_type and meta.eql(mapping.switch_state, switch_state)) {
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
    for (pointer_mappings.items, 0..) |mapping, i| {
        if (meta.eql(mapping.modifiers, modifiers) and mapping.event_code == event_code) {
            return i;
        }
    }

    return null;
}

fn parseEventCode(name: [:0]const u8, out: *?[]const u8) !u32 {
    const event_code = c.libevdev_event_code_from_name(c.EV_KEY, name.ptr);
    if (event_code < 1) {
        out.* = try fmt.allocPrint(util.gpa, "unknown button {s}", .{name});
        return Error.Other;
    }

    return @intCast(event_code);
}

fn parseKeysym(name: [:0]const u8, out: *?[]const u8) !xkb.Keysym {
    const keysym = xkb.Keysym.fromName(name, .case_insensitive);
    if (keysym == .NoSymbol) {
        out.* = try fmt.allocPrint(util.gpa, "invalid keysym '{s}'", .{name});
        return Error.Other;
    }

    // The case insensitive matching done by xkbcommon returns the first
    // lowercase match found if there are multiple matches that differ only in
    // case. This works great for alphabetic keys for example but there is one
    // problematic exception we handle specially here. For some reason there
    // exist both uppercase and lowercase versions of XF86ScreenSaver with
    // different keysym values for example. Switching to a case-sensitive match
    // would be too much of a breaking change at this point so fix this by
    // special-casing this exception.
    if (@intFromEnum(keysym) == xkb.Keysym.XF86Screensaver) {
        if (mem.eql(u8, name, "XF86Screensaver")) {
            return keysym;
        } else if (mem.eql(u8, name, "XF86ScreenSaver")) {
            return @enumFromInt(xkb.Keysym.XF86ScreenSaver);
        } else {
            out.* = try fmt.allocPrint(util.gpa, "ambiguous keysym name '{s}'", .{name});
            return Error.Other;
        }
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
            .{ .name = "Control", .field_name = "ctrl" },
            .{ .name = "Mod1", .field_name = "alt" },
            .{ .name = "Alt", .field_name = "alt" },
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
    return meta.stringToEnum(Switch.Type, switch_type_str) orelse {
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
            const lid_state = meta.stringToEnum(
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
            const tablet_state = meta.stringToEnum(
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

/// Remove a mapping from a given mode
///
/// Example:
/// unmap normal Mod4+Shift Return
pub fn unmap(seat: *Seat, args: []const [:0]const u8, out: *?[]const u8) Error!void {
    const result = flags.parser([:0]const u8, &.{
        .{ .name = "release", .kind = .boolean },
    }).parse(args[1..]) catch {
        return error.InvalidValue;
    };
    if (result.args.len < 3) return Error.NotEnoughArguments;
    if (result.args.len > 3) return Error.TooManyArguments;

    const mode_id = try modeNameToId(result.args[0], out);
    const modifiers = try parseModifiers(result.args[1], out);
    const keysym = try parseKeysym(result.args[2], out);

    const mode_mappings = &server.config.modes.items[mode_id].mappings;
    const mapping_idx = mappingExists(
        mode_mappings,
        modifiers,
        keysym,
        result.flags.release,
    ) orelse return;

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

    var mapping = mode_pointer_mappings.swapRemove(mapping_idx);
    mapping.deinit();
}
