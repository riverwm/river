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

pub const EventState = enum {
    enabled,
    disabled,
    @"disabled-on-external-mouse",

    pub fn apply(event_state: EventState, device: *c.libinput_device) void {
        const want: u32 = switch (event_state) {
            .enabled => c.LIBINPUT_CONFIG_SEND_EVENTS_ENABLED,
            .disabled => c.LIBINPUT_CONFIG_SEND_EVENTS_DISABLED,
            .@"disabled-on-external-mouse" => c.LIBINPUT_CONFIG_SEND_EVENTS_DISABLED_ON_EXTERNAL_MOUSE,
        };
        const current = c.libinput_device_config_send_events_get_mode(device);
        if (want != current) {
            _ = c.libinput_device_config_send_events_set_mode(device, want);
        }
    }
};

pub const AccelProfile = enum {
    none,
    flat,
    adaptive,

    pub fn apply(accel_profile: AccelProfile, device: *c.libinput_device) void {
        const want = @as(c_uint, switch (accel_profile) {
            .none => c.LIBINPUT_CONFIG_ACCEL_PROFILE_NONE,
            .flat => c.LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT,
            .adaptive => c.LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE,
        });
        if (c.libinput_device_config_accel_is_available(device) == 0) return;
        const current = c.libinput_device_config_accel_get_profile(device);
        if (want != current) {
            _ = c.libinput_device_config_accel_set_profile(device, want);
        }
    }
};

pub const ClickMethod = enum {
    none,
    @"button-areas",
    clickfinger,

    pub fn apply(click_method: ClickMethod, device: *c.libinput_device) void {
        const want = @as(c_uint, switch (click_method) {
            .none => c.LIBINPUT_CONFIG_CLICK_METHOD_NONE,
            .@"button-areas" => c.LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS,
            .clickfinger => c.LIBINPUT_CONFIG_CLICK_METHOD_CLICKFINGER,
        });
        const supports = c.libinput_device_config_click_get_methods(device);
        if (supports & want == 0) return;
        _ = c.libinput_device_config_click_set_method(device, want);
    }
};

pub const DragState = enum {
    disabled,
    enabled,

    pub fn apply(drag_state: DragState, device: *c.libinput_device) void {
        const want = @as(c_uint, switch (drag_state) {
            .disabled => c.LIBINPUT_CONFIG_DRAG_DISABLED,
            .enabled => c.LIBINPUT_CONFIG_DRAG_ENABLED,
        });
        if (c.libinput_device_config_tap_get_finger_count(device) <= 0) return;
        const current = c.libinput_device_config_tap_get_drag_enabled(device);
        if (want != current) {
            _ = c.libinput_device_config_tap_set_drag_enabled(device, want);
        }
    }
};

pub const DragLock = enum {
    disabled,
    enabled,

    pub fn apply(drag_lock: DragLock, device: *c.libinput_device) void {
        const want = @as(c_uint, switch (drag_lock) {
            .disabled => c.LIBINPUT_CONFIG_DRAG_LOCK_DISABLED,
            .enabled => c.LIBINPUT_CONFIG_DRAG_LOCK_ENABLED,
        });
        if (c.libinput_device_config_tap_get_finger_count(device) <= 0) return;
        const current = c.libinput_device_config_tap_get_drag_lock_enabled(device);
        if (want != current) {
            _ = c.libinput_device_config_tap_set_drag_lock_enabled(device, want);
        }
    }
};

pub const DwtState = enum {
    disabled,
    enabled,

    pub fn apply(dwt_state: DwtState, device: *c.libinput_device) void {
        const want = @as(c_uint, switch (dwt_state) {
            .disabled => c.LIBINPUT_CONFIG_DWT_DISABLED,
            .enabled => c.LIBINPUT_CONFIG_DWT_ENABLED,
        });
        if (c.libinput_device_config_dwt_is_available(device) == 0) return;
        const current = c.libinput_device_config_dwt_get_enabled(device);
        if (want != current) {
            _ = c.libinput_device_config_dwt_set_enabled(device, want);
        }
    }
};

pub const MiddleEmulation = enum {
    disabled,
    enabled,

    pub fn apply(middle_emulation: MiddleEmulation, device: *c.libinput_device) void {
        const want = @as(c_uint, switch (middle_emulation) {
            .disabled => c.LIBINPUT_CONFIG_MIDDLE_EMULATION_DISABLED,
            .enabled => c.LIBINPUT_CONFIG_MIDDLE_EMULATION_ENABLED,
        });
        if (c.libinput_device_config_middle_emulation_is_available(device) == 0) return;
        const current = c.libinput_device_config_middle_emulation_get_enabled(device);
        if (want != current) {
            _ = c.libinput_device_config_middle_emulation_set_enabled(device, want);
        }
    }
};

pub const NaturalScroll = enum {
    disabled,
    enabled,

    pub fn apply(natural_scroll: NaturalScroll, device: *c.libinput_device) void {
        const want: c_int = switch (natural_scroll) {
            .disabled => 0,
            .enabled => 1,
        };
        if (c.libinput_device_config_scroll_has_natural_scroll(device) == 0) return;
        const current = c.libinput_device_config_scroll_get_natural_scroll_enabled(device);
        if (want != current) {
            _ = c.libinput_device_config_scroll_set_natural_scroll_enabled(device, want);
        }
    }
};

pub const LeftHanded = enum {
    disabled,
    enabled,

    pub fn apply(left_handed: LeftHanded, device: *c.libinput_device) void {
        const want: c_int = switch (left_handed) {
            .disabled => 0,
            .enabled => 1,
        };
        if (c.libinput_device_config_left_handed_is_available(device) == 0) return;
        const current = c.libinput_device_config_left_handed_get(device);
        if (want != current) {
            _ = c.libinput_device_config_left_handed_set(device, want);
        }
    }
};

pub const TapState = enum {
    disabled,
    enabled,

    pub fn apply(tap_state: TapState, device: *c.libinput_device) void {
        const want = @as(c_uint, switch (tap_state) {
            .disabled => c.LIBINPUT_CONFIG_TAP_DISABLED,
            .enabled => c.LIBINPUT_CONFIG_TAP_ENABLED,
        });
        if (c.libinput_device_config_tap_get_finger_count(device) <= 0) return;
        const current = c.libinput_device_config_tap_get_enabled(device);
        if (want != current) {
            _ = c.libinput_device_config_tap_set_enabled(device, want);
        }
    }
};

pub const TapButtonMap = enum {
    @"left-middle-right",
    @"left-right-middle",

    pub fn apply(tap_button_map: TapButtonMap, device: *c.libinput_device) void {
        const want = @as(c_uint, switch (tap_button_map) {
            .@"left-right-middle" => c.LIBINPUT_CONFIG_TAP_MAP_LRM,
            .@"left-middle-right" => c.LIBINPUT_CONFIG_TAP_MAP_LMR,
        });
        if (c.libinput_device_config_tap_get_finger_count(device) <= 0) return;
        const current = c.libinput_device_config_tap_get_button_map(device);
        if (want != current) {
            _ = c.libinput_device_config_tap_set_button_map(device, want);
        }
    }
};

pub const PointerAccel = struct {
    value: f32,

    pub fn apply(pointer_accel: PointerAccel, device: *c.libinput_device) void {
        if (c.libinput_device_config_accel_is_available(device) == 0) return;
        if (c.libinput_device_config_accel_get_speed(device) != pointer_accel.value) {
            _ = c.libinput_device_config_accel_set_speed(device, pointer_accel.value);
        }
    }
};

pub const ScrollMethod = enum {
    none,
    @"two-finger",
    edge,
    button,

    pub fn apply(scroll_method: ScrollMethod, device: *c.libinput_device) void {
        const want = @as(c_uint, switch (scroll_method) {
            .none => c.LIBINPUT_CONFIG_SCROLL_NO_SCROLL,
            .@"two-finger" => c.LIBINPUT_CONFIG_SCROLL_2FG,
            .edge => c.LIBINPUT_CONFIG_SCROLL_EDGE,
            .button => c.LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN,
        });
        const supports = c.libinput_device_config_scroll_get_methods(device);
        if (supports & want == 0) return;
        _ = c.libinput_device_config_scroll_set_method(device, want);
    }
};

pub const ScrollButton = struct {
    button: u32,

    pub fn apply(scroll_button: ScrollButton, device: *c.libinput_device) void {
        const supports = c.libinput_device_config_scroll_get_methods(device);
        if (supports & ~@as(u32, c.LIBINPUT_CONFIG_SCROLL_NO_SCROLL) == 0) return;
        _ = c.libinput_device_config_scroll_set_button(device, scroll_button.button);
    }
};

identifier: []const u8,

// Note: Field names equal name of the setting in the 'input' command.
events: ?EventState = null,
@"accel-profile": ?AccelProfile = null,
@"click-method": ?ClickMethod = null,
drag: ?DragState = null,
@"drag-lock": ?DragLock = null,
@"disable-while-typing": ?DwtState = null,
@"middle-emulation": ?MiddleEmulation = null,
@"natural-scroll": ?NaturalScroll = null,
@"left-handed": ?LeftHanded = null,
tap: ?TapState = null,
@"tap-button-map": ?TapButtonMap = null,
@"pointer-accel": ?PointerAccel = null,
@"scroll-method": ?ScrollMethod = null,
@"scroll-button": ?ScrollButton = null,

pub fn deinit(self: *Self) void {
    util.gpa.free(self.identifier);
}

pub fn apply(self: *Self, device: *InputDevice) void {
    const libinput_device: *c.libinput_device = @ptrCast(device.wlr_device.getLibinputDevice() orelse return);
    log.debug("applying input configuration to device: {s}", .{device.identifier});

    inline for (@typeInfo(Self).Struct.fields) |field| {
        if (comptime mem.eql(u8, field.name, "identifier")) continue;

        if (@field(self, field.name)) |setting| {
            log.debug("applying setting: {s}", .{field.name});
            setting.apply(libinput_device);
        }
    }
}

pub fn parse(self: *Self, setting: []const u8, value: []const u8) !void {
    inline for (@typeInfo(Self).Struct.fields) |field| {
        if (comptime mem.eql(u8, field.name, "identifier")) continue;

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
    try writer.print("{s}\n", .{self.identifier});

    inline for (@typeInfo(Self).Struct.fields) |field| {
        if (comptime mem.eql(u8, field.name, "identifier")) continue;
        if (@field(self, field.name)) |setting| {
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
