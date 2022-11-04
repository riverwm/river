// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 The River Developers
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
const mem = std.mem;
const meta = std.meta;

const server = &@import("../main.zig").server;
const util = @import("../util.zig");
const c = @import("../c.zig");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");
const InputConfig = @import("../InputConfig.zig");
const InputManager = @import("../InputManager.zig");

pub fn listInputs(
    _: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len > 1) return error.TooManyArguments;

    var input_list = std.ArrayList(u8).init(util.gpa);
    const writer = input_list.writer();
    var prev = false;

    var it = server.input_manager.devices.iterator(.forward);
    while (it.next()) |device| {
        const configured = for (server.input_manager.configs.items) |*input_config| {
            if (mem.eql(u8, input_config.identifier, device.identifier)) {
                break true;
            }
        } else false;

        if (prev) try input_list.appendSlice("\n");
        prev = true;

        try writer.print("{s}\n\tconfigured: {}\n", .{
            device.identifier,
            configured,
        });
    }

    out.* = input_list.toOwnedSlice();
}

pub fn listInputConfigs(
    _: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len > 1) return error.TooManyArguments;

    var input_list = std.ArrayList(u8).init(util.gpa);
    const writer = input_list.writer();

    for (server.input_manager.configs.items) |*input_config, i| {
        if (i > 0) try input_list.appendSlice("\n");

        try writer.print("{s}\n", .{input_config.identifier});

        if (input_config.event_state) |event_state| {
            try writer.print("\tevents: {s}\n", .{@tagName(event_state)});
        }
        if (input_config.accel_profile) |accel_profile| {
            try writer.print("\taccel-profile: {s}\n", .{@tagName(accel_profile)});
        }
        if (input_config.click_method) |click_method| {
            try writer.print("\tclick-method: {s}\n", .{@tagName(click_method)});
        }
        if (input_config.drag_state) |drag_state| {
            try writer.print("\tdrag: {s}\n", .{@tagName(drag_state)});
        }
        if (input_config.drag_lock) |drag_lock| {
            try writer.print("\tdrag-lock: {s}\n", .{@tagName(drag_lock)});
        }
        if (input_config.dwt_state) |dwt_state| {
            try writer.print("\tdisable-while-typing: {s}\n", .{@tagName(dwt_state)});
        }
        if (input_config.middle_emulation) |middle_emulation| {
            try writer.print("\tmiddle-emulation: {s}\n", .{@tagName(middle_emulation)});
        }
        if (input_config.natural_scroll) |natural_scroll| {
            try writer.print("\tnatural-scroll: {s}\n", .{@tagName(natural_scroll)});
        }
        if (input_config.left_handed) |left_handed| {
            try writer.print("\tleft-handed: {s}\n", .{@tagName(left_handed)});
        }
        if (input_config.tap_state) |tap_state| {
            try writer.print("\ttap: {s}\n", .{@tagName(tap_state)});
        }
        if (input_config.tap_button_map) |tap_button_map| {
            try writer.print("\ttap-button-map: {s}\n", .{@tagName(tap_button_map)});
        }
        if (input_config.pointer_accel) |pointer_accel| {
            try writer.print("\tpointer-accel: {d}\n", .{pointer_accel.value});
        }
        if (input_config.scroll_method) |scroll_method| {
            try writer.print("\tscroll-method: {s}\n", .{@tagName(scroll_method)});
        }
        if (input_config.scroll_button) |scroll_button| {
            try writer.print("\tscroll-button: {s}\n", .{
                mem.sliceTo(c.libevdev_event_code_get_name(c.EV_KEY, scroll_button.button), 0),
            });
        }
    }

    out.* = input_list.toOwnedSlice();
}

pub fn input(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 4) return Error.NotEnoughArguments;
    if (args.len > 4) return Error.TooManyArguments;

    // Try to find an existing InputConfig with matching identifier, or create
    // a new one if none was found.
    var new = false;
    const input_config = for (server.input_manager.configs.items) |*input_config| {
        if (mem.eql(u8, input_config.identifier, args[1])) break input_config;
    } else blk: {
        try server.input_manager.configs.ensureUnusedCapacity(1);
        server.input_manager.configs.appendAssumeCapacity(.{
            .identifier = try util.gpa.dupe(u8, args[1]),
        });
        new = true;
        break :blk &server.input_manager.configs.items[server.input_manager.configs.items.len - 1];
    };
    errdefer {
        if (new) {
            var cfg = server.input_manager.configs.pop();
            cfg.deinit();
        }
    }

    if (mem.eql(u8, "events", args[2])) {
        input_config.event_state = meta.stringToEnum(InputConfig.EventState, args[3]) orelse
            return Error.UnknownOption;
    } else if (mem.eql(u8, "accel-profile", args[2])) {
        input_config.accel_profile = meta.stringToEnum(InputConfig.AccelProfile, args[3]) orelse
            return Error.UnknownOption;
    } else if (mem.eql(u8, "click-method", args[2])) {
        input_config.click_method = meta.stringToEnum(InputConfig.ClickMethod, args[3]) orelse
            return Error.UnknownOption;
    } else if (mem.eql(u8, "drag", args[2])) {
        input_config.drag_state = meta.stringToEnum(InputConfig.DragState, args[3]) orelse
            return Error.UnknownOption;
    } else if (mem.eql(u8, "drag-lock", args[2])) {
        input_config.drag_lock = meta.stringToEnum(InputConfig.DragLock, args[3]) orelse
            return Error.UnknownOption;
    } else if (mem.eql(u8, "disable-while-typing", args[2])) {
        input_config.dwt_state = meta.stringToEnum(InputConfig.DwtState, args[3]) orelse
            return Error.UnknownOption;
    } else if (mem.eql(u8, "middle-emulation", args[2])) {
        input_config.middle_emulation = meta.stringToEnum(InputConfig.MiddleEmulation, args[3]) orelse
            return Error.UnknownOption;
    } else if (mem.eql(u8, "natural-scroll", args[2])) {
        input_config.natural_scroll = meta.stringToEnum(InputConfig.NaturalScroll, args[3]) orelse
            return Error.UnknownOption;
    } else if (mem.eql(u8, "left-handed", args[2])) {
        input_config.left_handed = meta.stringToEnum(InputConfig.LeftHanded, args[3]) orelse
            return Error.UnknownOption;
    } else if (mem.eql(u8, "tap", args[2])) {
        input_config.tap_state = meta.stringToEnum(InputConfig.TapState, args[3]) orelse
            return Error.UnknownOption;
    } else if (mem.eql(u8, "tap-button-map", args[2])) {
        input_config.tap_button_map = meta.stringToEnum(InputConfig.TapButtonMap, args[3]) orelse
            return Error.UnknownOption;
    } else if (mem.eql(u8, "pointer-accel", args[2])) {
        input_config.pointer_accel = InputConfig.PointerAccel{
            .value = std.math.clamp(
                try std.fmt.parseFloat(f32, args[3]),
                @as(f32, -1.0),
                @as(f32, 1.0),
            ),
        };
    } else if (mem.eql(u8, "scroll-method", args[2])) {
        input_config.scroll_method = meta.stringToEnum(InputConfig.ScrollMethod, args[3]) orelse
            return Error.UnknownOption;
    } else if (mem.eql(u8, "scroll-button", args[2])) {
        const ret = c.libevdev_event_code_from_name(c.EV_KEY, args[3].ptr);
        if (ret < 1) return Error.InvalidButton;
        input_config.scroll_button = InputConfig.ScrollButton{ .button = @intCast(u32, ret) };
    } else {
        return Error.UnknownCommand;
    }

    // Update matching existing input devices.
    var it = server.input_manager.devices.iterator(.forward);
    while (it.next()) |device| {
        if (mem.eql(u8, device.identifier, args[1])) {
            input_config.apply(device);
            // We don't break here because it is common to have multiple input
            // devices with the same identifier.
        }
    }
}
