// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 - 2024 The River Developers
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

const build_options = @import("build_options");
const std = @import("std");
const mem = std.mem;
const math = std.math;
const meta = std.meta;
const wlr = @import("wlroots");

const log = std.log.scoped(.input_config);

const c = @import("c.zig");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const InputDevice = @import("InputDevice.zig");
const Tablet = @import("Tablet.zig");

pub const EventState = enum {
    enabled,
    disabled,
    @"disabled-on-external-mouse",

    fn apply(event_state: EventState, device: *c.libinput_device) void {
        _ = c.libinput_device_config_send_events_set_mode(device, switch (event_state) {
            .enabled => c.LIBINPUT_CONFIG_SEND_EVENTS_ENABLED,
            .disabled => c.LIBINPUT_CONFIG_SEND_EVENTS_DISABLED,
            .@"disabled-on-external-mouse" => c.LIBINPUT_CONFIG_SEND_EVENTS_DISABLED_ON_EXTERNAL_MOUSE,
        });
    }
};

pub const AccelProfile = enum {
    none,
    flat,
    adaptive,

    fn apply(accel_profile: AccelProfile, device: *c.libinput_device) void {
        _ = c.libinput_device_config_accel_set_profile(device, switch (accel_profile) {
            .none => c.LIBINPUT_CONFIG_ACCEL_PROFILE_NONE,
            .flat => c.LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT,
            .adaptive => c.LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE,
        });
    }
};

pub const ClickMethod = enum {
    none,
    @"button-areas",
    clickfinger,

    fn apply(click_method: ClickMethod, device: *c.libinput_device) void {
        _ = c.libinput_device_config_click_set_method(device, switch (click_method) {
            .none => c.LIBINPUT_CONFIG_CLICK_METHOD_NONE,
            .@"button-areas" => c.LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS,
            .clickfinger => c.LIBINPUT_CONFIG_CLICK_METHOD_CLICKFINGER,
        });
    }
};

pub const DragState = enum {
    disabled,
    enabled,

    fn apply(drag_state: DragState, device: *c.libinput_device) void {
        _ = c.libinput_device_config_tap_set_drag_enabled(device, switch (drag_state) {
            .disabled => c.LIBINPUT_CONFIG_DRAG_DISABLED,
            .enabled => c.LIBINPUT_CONFIG_DRAG_ENABLED,
        });
    }
};

pub const DragLock = enum {
    disabled,
    enabled,

    fn apply(drag_lock: DragLock, device: *c.libinput_device) void {
        _ = c.libinput_device_config_tap_set_drag_lock_enabled(device, switch (drag_lock) {
            .disabled => c.LIBINPUT_CONFIG_DRAG_LOCK_DISABLED,
            .enabled => c.LIBINPUT_CONFIG_DRAG_LOCK_ENABLED,
        });
    }
};

pub const DwtState = enum {
    disabled,
    enabled,

    fn apply(dwt_state: DwtState, device: *c.libinput_device) void {
        _ = c.libinput_device_config_dwt_set_enabled(device, switch (dwt_state) {
            .disabled => c.LIBINPUT_CONFIG_DWT_DISABLED,
            .enabled => c.LIBINPUT_CONFIG_DWT_ENABLED,
        });
    }
};

pub const DwtpState = enum {
    disabled,
    enabled,

    fn apply(dwtp_state: DwtpState, device: *c.libinput_device) void {
        _ = c.libinput_device_config_dwtp_set_enabled(device, switch (dwtp_state) {
            .disabled => c.LIBINPUT_CONFIG_DWTP_DISABLED,
            .enabled => c.LIBINPUT_CONFIG_DWTP_ENABLED,
        });
    }
};

pub const MiddleEmulation = enum {
    disabled,
    enabled,

    fn apply(middle_emulation: MiddleEmulation, device: *c.libinput_device) void {
        _ = c.libinput_device_config_middle_emulation_set_enabled(device, switch (middle_emulation) {
            .disabled => c.LIBINPUT_CONFIG_MIDDLE_EMULATION_DISABLED,
            .enabled => c.LIBINPUT_CONFIG_MIDDLE_EMULATION_ENABLED,
        });
    }
};

pub const NaturalScroll = enum {
    disabled,
    enabled,

    fn apply(natural_scroll: NaturalScroll, device: *c.libinput_device) void {
        _ = c.libinput_device_config_scroll_set_natural_scroll_enabled(device, switch (natural_scroll) {
            .disabled => 0,
            .enabled => 1,
        });
    }
};

pub const LeftHanded = enum {
    disabled,
    enabled,

    fn apply(left_handed: LeftHanded, device: *c.libinput_device) void {
        _ = c.libinput_device_config_left_handed_set(device, switch (left_handed) {
            .disabled => 0,
            .enabled => 1,
        });
    }
};

pub const TapState = enum {
    disabled,
    enabled,

    fn apply(tap_state: TapState, device: *c.libinput_device) void {
        _ = c.libinput_device_config_tap_set_enabled(device, switch (tap_state) {
            .disabled => c.LIBINPUT_CONFIG_TAP_DISABLED,
            .enabled => c.LIBINPUT_CONFIG_TAP_ENABLED,
        });
    }
};

pub const TapButtonMap = enum {
    @"left-middle-right",
    @"left-right-middle",

    fn apply(tap_button_map: TapButtonMap, device: *c.libinput_device) void {
        _ = c.libinput_device_config_tap_set_button_map(device, switch (tap_button_map) {
            .@"left-right-middle" => c.LIBINPUT_CONFIG_TAP_MAP_LRM,
            .@"left-middle-right" => c.LIBINPUT_CONFIG_TAP_MAP_LMR,
        });
    }
};

pub const PointerAccel = struct {
    value: f32,

    fn apply(pointer_accel: PointerAccel, device: *c.libinput_device) void {
        _ = c.libinput_device_config_accel_set_speed(device, pointer_accel.value);
    }
};

pub const ScrollMethod = enum {
    none,
    @"two-finger",
    edge,
    button,

    fn apply(scroll_method: ScrollMethod, device: *c.libinput_device) void {
        _ = c.libinput_device_config_scroll_set_method(device, switch (scroll_method) {
            .none => c.LIBINPUT_CONFIG_SCROLL_NO_SCROLL,
            .@"two-finger" => c.LIBINPUT_CONFIG_SCROLL_2FG,
            .edge => c.LIBINPUT_CONFIG_SCROLL_EDGE,
            .button => c.LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN,
        });
    }
};

pub const ScrollButton = struct {
    button: u32,

    fn apply(scroll_button: ScrollButton, device: *c.libinput_device) void {
        _ = c.libinput_device_config_scroll_set_button(device, scroll_button.button);
    }
};

pub const MapToOutput = struct {
    output_name: ?[]const u8,

    fn apply(map_to_output: MapToOutput, device: *InputDevice) void {
        const wlr_output = blk: {
            if (map_to_output.output_name) |name| {
                var it = server.root.active_outputs.iterator(.forward);
                while (it.next()) |output| {
                    if (mem.eql(u8, mem.span(output.wlr_output.name), name)) {
                        break :blk output.wlr_output;
                    }
                }
            }
            break :blk null;
        };

        switch (device.wlr_device.type) {
            .pointer, .touch, .tablet_tool => {
                log.debug("mapping input '{s}' -> '{s}'", .{
                    device.identifier,
                    if (wlr_output) |o| o.name else "<no output>",
                });

                device.seat.cursor.wlr_cursor.mapInputToOutput(device.wlr_device, wlr_output);

                if (device.wlr_device.type == .tablet_tool) {
                    const tablet = @fieldParentPtr(Tablet, "device", device);
                    tablet.output_mapping = wlr_output;
                }
            },

            // These devices do not support being mapped to outputs.
            .keyboard, .tablet_pad, .switch_device => {},
        }
    }
};

glob: []const u8,

// Note: Field names equal name of the setting in the 'input' command.
events: ?EventState = null,
@"accel-profile": ?AccelProfile = null,
@"click-method": ?ClickMethod = null,
drag: ?DragState = null,
@"drag-lock": ?DragLock = null,
@"disable-while-typing": ?DwtState = null,
@"disable-while-trackpointing": ?DwtpState = null,
@"middle-emulation": ?MiddleEmulation = null,
@"natural-scroll": ?NaturalScroll = null,
@"left-handed": ?LeftHanded = null,
tap: ?TapState = null,
@"tap-button-map": ?TapButtonMap = null,
@"pointer-accel": ?PointerAccel = null,
@"scroll-method": ?ScrollMethod = null,
@"scroll-button": ?ScrollButton = null,
@"map-to-output": MapToOutput = .{ .output_name = null },

pub fn deinit(self: *Self) void {
    util.gpa.free(self.glob);
    if (self.@"map-to-output".output_name) |output_name| {
        util.gpa.free(output_name);
    }
}

pub fn apply(self: *const Self, device: *InputDevice) void {
    const libinput_device: *c.libinput_device = @ptrCast(device.wlr_device.getLibinputDevice() orelse return);
    log.debug("applying input configuration '{s}' to device '{s}'.", .{ self.glob, device.identifier });

    inline for (@typeInfo(Self).Struct.fields) |field| {
        if (comptime mem.eql(u8, field.name, "glob")) continue;

        if (comptime mem.eql(u8, field.name, "map-to-output")) {
            @field(self, field.name).apply(device);
        } else if (@field(self, field.name)) |setting| {
            log.debug("applying setting: {s}", .{field.name});
            setting.apply(libinput_device);
        }
    }
}

pub fn parse(self: *Self, setting: []const u8, value: []const u8) !void {
    inline for (@typeInfo(Self).Struct.fields) |field| {
        if (comptime mem.eql(u8, field.name, "glob")) continue;

        if (mem.eql(u8, setting, field.name)) {
            // Special-case the settings which are not enums.
            if (comptime mem.eql(u8, field.name, "pointer-accel")) {
                self.@"pointer-accel" = PointerAccel{
                    .value = math.clamp(try std.fmt.parseFloat(f32, value), -1.0, 1.0),
                };
            } else if (comptime mem.eql(u8, field.name, "scroll-button")) {
                const ret = c.libevdev_event_code_from_name(c.EV_KEY, value.ptr);
                if (ret < 1) return error.InvalidButton;
                self.@"scroll-button" = ScrollButton{ .button = @intCast(ret) };
            } else if (comptime mem.eql(u8, field.name, "map-to-output")) {
                const output_name_owned = blk: {
                    if (mem.eql(u8, value, "disabled")) {
                        break :blk null;
                    } else {
                        break :blk try util.gpa.dupe(u8, value);
                    }
                };

                if (self.@"map-to-output".output_name) |old| util.gpa.free(old);
                self.@"map-to-output" = .{ .output_name = output_name_owned };
            } else {
                const T = @typeInfo(field.type).Optional.child;
                if (@typeInfo(T) != .Enum) {
                    @compileError("You forgot to implement parsing for an input configuration setting.");
                }
                @field(self, field.name) = meta.stringToEnum(T, value) orelse
                    return error.UnknownOption;
            }

            return;
        }
    }

    return error.UnknownCommand;
}

pub fn write(self: *Self, writer: anytype) !void {
    try writer.print("{s}\n", .{self.glob});

    inline for (@typeInfo(Self).Struct.fields) |field| {
        if (comptime mem.eql(u8, field.name, "glob")) continue;

        if (comptime mem.eql(u8, field.name, "map-to-output")) {
            if (@field(self, field.name).output_name) |output_name| {
                try writer.print("\tmap-to-output: {s}\n", .{output_name});
            }
        } else if (@field(self, field.name)) |setting| {
            // Special-case the settings which are not enums.
            if (comptime mem.eql(u8, field.name, "pointer-accel")) {
                try writer.print("\tpointer-accel: {d}\n", .{setting.value});
            } else if (comptime mem.eql(u8, field.name, "scroll-button")) {
                try writer.print("\tscroll-button: {s}\n", .{
                    mem.sliceTo(c.libevdev_event_code_get_name(c.EV_KEY, setting.button), 0),
                });
            } else {
                const T = @typeInfo(field.type).Optional.child;
                if (@typeInfo(T) != .Enum) {
                    @compileError("You forgot to implement listing for an input configuration setting.");
                }
                try writer.print("\t{s}: {s}\n", .{ field.name, @tagName(setting) });
            }
        }
    }
}
