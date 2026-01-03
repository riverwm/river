// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const LibinputDevice = @This();

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;

const c = @import("c.zig").c;
const server = &@import("main.zig").server;
const util = @import("util.zig");

const InputDevice = @import("InputDevice.zig");
const LibinputAccelConfig = @import("LibinputAccelConfig.zig");

const log = std.log.scoped(.input);

libinput: *c.libinput_device,
objects: wl.list.Head(river.LibinputDeviceV1, null),

/// LibinputConfig.devices
link: wl.list.Link,

pub fn init(device: *LibinputDevice, handle: *c.libinput_device) void {
    device.* = .{
        .libinput = handle,
        .objects = undefined,
        .link = undefined,
    };
    device.objects.init();
    server.libinput_config.devices.append(device);
    {
        var it = server.libinput_config.objects.iterator(.forward);
        while (it.next()) |config_v1| device.createObject(config_v1);
    }
}

pub fn createObject(device: *LibinputDevice, config_v1: *river.LibinputConfigV1) void {
    const object = river.LibinputDeviceV1.create(config_v1.getClient(), config_v1.getVersion(), 0) catch {
        log.err("out of memory", .{});
        config_v1.postNoMemory();
        return;
    };
    device.objects.append(object);
    object.setHandler(*LibinputDevice, handleRequest, handleDestroy, device);
    config_v1.sendLibinputDevice(object);
    {
        const base: *InputDevice = @fieldParentPtr("libinput", device);
        assert(!base.virtual);
        var it = base.objects.iterator(.forward);
        while (it.next()) |input_device_v1| {
            if (object.getClient() == input_device_v1.getClient()) {
                object.sendInputDevice(input_device_v1);
            }
        }
    }
    object.sendSendEventsSupport(@bitCast(c.libinput_device_config_send_events_get_modes(device.libinput)));
    object.sendSendEventsDefault(@bitCast(c.libinput_device_config_send_events_get_default_mode(device.libinput)));
    object.sendSendEventsCurrent(@bitCast(c.libinput_device_config_send_events_get_mode(device.libinput)));
    const tap_finger_count = c.libinput_device_config_tap_get_finger_count(device.libinput);
    object.sendTapSupport(tap_finger_count);
    if (tap_finger_count > 0) {
        object.sendTapDefault(@enumFromInt(c.libinput_device_config_tap_get_default_enabled(device.libinput)));
        object.sendTapCurrent(@enumFromInt(c.libinput_device_config_tap_get_enabled(device.libinput)));
        object.sendTapButtonMapDefault(@enumFromInt(c.libinput_device_config_tap_get_default_button_map(device.libinput)));
        object.sendTapButtonMapCurrent(@enumFromInt(c.libinput_device_config_tap_get_button_map(device.libinput)));
        object.sendDragDefault(@enumFromInt(c.libinput_device_config_tap_get_default_drag_enabled(device.libinput)));
        object.sendDragCurrent(@enumFromInt(c.libinput_device_config_tap_get_drag_enabled(device.libinput)));
        object.sendDragLockDefault(@enumFromInt(c.libinput_device_config_tap_get_default_drag_lock_enabled(device.libinput)));
        object.sendDragLockCurrent(@enumFromInt(c.libinput_device_config_tap_get_drag_lock_enabled(device.libinput)));
    }
    const three_finger_drag_finger_count = c.libinput_device_config_3fg_drag_get_finger_count(device.libinput);
    object.sendThreeFingerDragSupport(three_finger_drag_finger_count);
    if (three_finger_drag_finger_count >= 3) {
        object.sendThreeFingerDragDefault(@enumFromInt(c.libinput_device_config_3fg_drag_get_default_enabled(device.libinput)));
        object.sendThreeFingerDragCurrent(@enumFromInt(c.libinput_device_config_3fg_drag_get_enabled(device.libinput)));
    }
    const has_matrix = c.libinput_device_config_calibration_has_matrix(device.libinput);
    object.sendCalibrationMatrixSupport(has_matrix);
    if (has_matrix != 0) {
        var matrix: [6]f32 = undefined;
        const bytes: []u8 = @ptrCast(&matrix);
        var array: wl.Array = .{ .size = bytes.len, .alloc = bytes.len, .data = bytes.ptr };
        _ = c.libinput_device_config_calibration_get_default_matrix(device.libinput, &matrix);
        object.sendCalibrationMatrixDefault(&array);
        _ = c.libinput_device_config_calibration_get_matrix(device.libinput, &matrix);
        object.sendCalibrationMatrixCurrent(&array);
    }
    const profiles = c.libinput_device_config_accel_get_profiles(device.libinput);
    object.sendAccelProfilesSupport(@bitCast(profiles));
    if (profiles != 0) {
        object.sendAccelProfileDefault(@enumFromInt(c.libinput_device_config_accel_get_default_profile(device.libinput)));
        object.sendAccelProfileCurrent(@enumFromInt(c.libinput_device_config_accel_get_profile(device.libinput)));
        var speed: [1]f64 = .{c.libinput_device_config_accel_get_default_speed(device.libinput)};
        const bytes: []u8 = @ptrCast(&speed);
        var array: wl.Array = .{ .size = bytes.len, .alloc = bytes.len, .data = bytes.ptr };
        object.sendAccelSpeedDefault(&array);
        speed = .{c.libinput_device_config_accel_get_speed(device.libinput)};
        object.sendAccelSpeedCurrent(&array);
    }
    const natural_scroll = c.libinput_device_config_scroll_has_natural_scroll(device.libinput);
    object.sendNaturalScrollSupport(natural_scroll);
    if (natural_scroll != 0) {
        const default = c.libinput_device_config_scroll_get_default_natural_scroll_enabled(device.libinput);
        object.sendNaturalScrollDefault(if (default != 0) .enabled else .disabled);
        const current = c.libinput_device_config_scroll_get_natural_scroll_enabled(device.libinput);
        object.sendNaturalScrollCurrent(if (current != 0) .enabled else .disabled);
    }
    const left_handed = c.libinput_device_config_left_handed_is_available(device.libinput);
    object.sendLeftHandedSupport(left_handed);
    if (left_handed != 0) {
        const default = c.libinput_device_config_left_handed_get_default(device.libinput);
        object.sendLeftHandedDefault(if (default != 0) .enabled else .disabled);
        const current = c.libinput_device_config_left_handed_get(device.libinput);
        object.sendLeftHandedCurrent(if (current != 0) .enabled else .disabled);
    }
    const click_methods = c.libinput_device_config_click_get_methods(device.libinput);
    object.sendClickMethodSupport(@bitCast(click_methods));
    if (click_methods != 0) {
        object.sendClickMethodDefault(@enumFromInt(c.libinput_device_config_click_get_default_method(device.libinput)));
        object.sendClickMethodCurrent(@enumFromInt(c.libinput_device_config_click_get_method(device.libinput)));
        if (click_methods & c.LIBINPUT_CONFIG_CLICK_METHOD_CLICKFINGER != 0) {
            object.sendClickfingerButtonMapDefault(@enumFromInt(c.libinput_device_config_click_get_default_clickfinger_button_map(device.libinput)));
            object.sendClickfingerButtonMapCurrent(@enumFromInt(c.libinput_device_config_click_get_clickfinger_button_map(device.libinput)));
        }
    }
    const middle_emulation = c.libinput_device_config_middle_emulation_is_available(device.libinput);
    object.sendMiddleEmulationSupport(middle_emulation);
    if (middle_emulation != 0) {
        object.sendMiddleEmulationDefault(@enumFromInt(c.libinput_device_config_middle_emulation_get_default_enabled(device.libinput)));
        object.sendMiddleEmulationCurrent(@enumFromInt(c.libinput_device_config_middle_emulation_get_enabled(device.libinput)));
    }
    const scroll_methods = c.libinput_device_config_scroll_get_methods(device.libinput);
    object.sendScrollMethodSupport(@bitCast(scroll_methods));
    if (scroll_methods != 0) {
        object.sendScrollMethodDefault(@enumFromInt(c.libinput_device_config_scroll_get_default_method(device.libinput)));
        object.sendScrollMethodCurrent(@enumFromInt(c.libinput_device_config_scroll_get_method(device.libinput)));
        if (scroll_methods & c.LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN != 0) {
            object.sendScrollButtonDefault(c.libinput_device_config_scroll_get_default_button(device.libinput));
            object.sendScrollButtonCurrent(c.libinput_device_config_scroll_get_button(device.libinput));
            object.sendScrollButtonLockDefault(@enumFromInt(c.libinput_device_config_scroll_get_default_button_lock(device.libinput)));
            object.sendScrollButtonLockCurrent(@enumFromInt(c.libinput_device_config_scroll_get_button_lock(device.libinput)));
        }
    }
    const dwt = c.libinput_device_config_dwt_is_available(device.libinput);
    object.sendDwtSupport(dwt);
    if (dwt != 0) {
        const default = c.libinput_device_config_dwt_get_default_enabled(device.libinput);
        object.sendDwtDefault(if (default != 0) .enabled else .disabled);
        const current = c.libinput_device_config_dwt_get_enabled(device.libinput);
        object.sendDwtCurrent(if (current != 0) .enabled else .disabled);
    }
    const dwtp = c.libinput_device_config_dwtp_is_available(device.libinput);
    object.sendDwtpSupport(dwtp);
    if (dwtp != 0) {
        const default = c.libinput_device_config_dwtp_get_default_enabled(device.libinput);
        object.sendDwtpDefault(if (default != 0) .enabled else .disabled);
        const current = c.libinput_device_config_dwtp_get_enabled(device.libinput);
        object.sendDwtpCurrent(if (current != 0) .enabled else .disabled);
    }
    const rotation = c.libinput_device_config_rotation_is_available(device.libinput);
    object.sendRotationSupport(rotation);
    if (rotation != 0) {
        object.sendRotationDefault(c.libinput_device_config_rotation_get_default_angle(device.libinput));
        object.sendRotationCurrent(c.libinput_device_config_rotation_get_angle(device.libinput));
    }
}

pub fn deinit(device: *LibinputDevice) void {
    {
        var it = device.objects.iterator(.forward);
        while (it.next()) |object| {
            object.getLink().remove();
            object.sendRemoved();
            object.setHandler(?*anyopaque, handleRequestInert, null, null);
        }
    }
    assert(device.objects.empty());
    device.link.remove();
}

fn handleRequestInert(
    object: *river.LibinputDeviceV1,
    request: river.LibinputDeviceV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) object.destroy();
}

fn handleDestroy(object: *river.LibinputDeviceV1, _: *LibinputDevice) void {
    object.getLink().remove();
}

fn handleRequest(
    object: *river.LibinputDeviceV1,
    request: river.LibinputDeviceV1.Request,
    device: *LibinputDevice,
) void {
    switch (request) {
        .destroy => object.destroy(),
        .set_send_events => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_send_events_set_mode(device.libinput, @bitCast(args.mode));
            if (result.send(status)) {
                const current = c.libinput_device_config_send_events_get_mode(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendSendEventsCurrent(@bitCast(current));
            }
        },
        .set_tap => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_tap_set_enabled(device.libinput, switch (args.state) {
                .disabled => c.LIBINPUT_CONFIG_TAP_DISABLED,
                .enabled => c.LIBINPUT_CONFIG_TAP_ENABLED,
                _ => {
                    object.postError(.invalid_arg, "invalid tap_state enum value");
                    return;
                },
            });
            if (result.send(status)) {
                const current = c.libinput_device_config_tap_get_enabled(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendTapCurrent(@enumFromInt(current));
            }
        },
        .set_tap_button_map => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_tap_set_button_map(device.libinput, switch (args.button_map) {
                .lrm => c.LIBINPUT_CONFIG_TAP_MAP_LRM,
                .lmr => c.LIBINPUT_CONFIG_TAP_MAP_LMR,
                _ => {
                    object.postError(.invalid_arg, "invalid tap_button_map enum value");
                    return;
                },
            });
            if (result.send(status)) {
                const current = c.libinput_device_config_tap_get_button_map(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendTapButtonMapCurrent(@enumFromInt(current));
            }
        },
        .set_drag => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_tap_set_drag_enabled(device.libinput, switch (args.state) {
                .disabled => c.LIBINPUT_CONFIG_DRAG_DISABLED,
                .enabled => c.LIBINPUT_CONFIG_DRAG_ENABLED,
                _ => {
                    object.postError(.invalid_arg, "invalid drag_state enum value");
                    return;
                },
            });
            if (result.send(status)) {
                const current = c.libinput_device_config_tap_get_drag_enabled(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendDragCurrent(@enumFromInt(current));
            }
        },
        .set_drag_lock => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_tap_set_drag_lock_enabled(device.libinput, switch (args.state) {
                .disabled => c.LIBINPUT_CONFIG_DRAG_LOCK_DISABLED,
                .enabled_timeout => c.LIBINPUT_CONFIG_DRAG_LOCK_ENABLED_TIMEOUT,
                .enabled_sticky => c.LIBINPUT_CONFIG_DRAG_LOCK_ENABLED_STICKY,
                _ => {
                    object.postError(.invalid_arg, "invalid drag_lock_state enum value");
                    return;
                },
            });
            if (result.send(status)) {
                const current = c.libinput_device_config_tap_get_drag_lock_enabled(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendDragLockCurrent(@enumFromInt(current));
            }
        },
        .set_three_finger_drag => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_3fg_drag_set_enabled(device.libinput, switch (args.state) {
                .disabled => c.LIBINPUT_CONFIG_3FG_DRAG_DISABLED,
                .enabled_3fg => c.LIBINPUT_CONFIG_3FG_DRAG_ENABLED_3FG,
                .enabled_4fg => c.LIBINPUT_CONFIG_3FG_DRAG_ENABLED_4FG,
                _ => {
                    object.postError(.invalid_arg, "invalid three_finger_drag_state enum value");
                    return;
                },
            });
            if (result.send(status)) {
                const current = c.libinput_device_config_3fg_drag_get_enabled(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendThreeFingerDragCurrent(@enumFromInt(current));
            }
        },
        .set_calibration_matrix => |args| {
            if (args.matrix.size != @sizeOf([6]f32)) {
                object.postError(.invalid_arg, "invalid calibration matrix");
                return;
            }
            const matrix = args.matrix.slice(f32)[0..6];
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_calibration_set_matrix(device.libinput, matrix);
            if (result.send(status)) {
                var current: [6]f32 = undefined;
                const bytes: []u8 = @ptrCast(&current);
                var array: wl.Array = .{ .size = bytes.len, .alloc = bytes.len, .data = bytes.ptr };
                _ = c.libinput_device_config_calibration_get_matrix(device.libinput, &current);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendCalibrationMatrixCurrent(&array);
            }
        },
        .set_accel_profile => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_accel_set_profile(device.libinput, switch (args.profile) {
                .none => c.LIBINPUT_CONFIG_ACCEL_PROFILE_NONE,
                .flat => c.LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT,
                .adaptive => c.LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE,
                .custom => c.LIBINPUT_CONFIG_ACCEL_PROFILE_CUSTOM,
                _ => {
                    object.postError(.invalid_arg, "invalid accel_profile enum value");
                    return;
                },
            });
            if (result.send(status)) {
                const current = c.libinput_device_config_accel_get_profile(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendAccelProfileCurrent(@enumFromInt(current));
            }
        },
        .set_accel_speed => |args| {
            if (args.speed.size != @sizeOf(f32)) {
                object.postError(.invalid_arg, "invalid accel speed");
                return;
            }
            const speed = args.speed.slice(f32)[0];
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_accel_set_speed(device.libinput, speed);
            if (result.send(status)) {
                var current: [1]f64 = .{c.libinput_device_config_accel_get_speed(device.libinput)};
                const bytes: []u8 = @ptrCast(&current);
                var array: wl.Array = .{ .size = bytes.len, .alloc = bytes.len, .data = bytes.ptr };
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendAccelSpeedCurrent(&array);
            }
        },
        .apply_accel_config => |args| {
            const result = Result.create(object, args.result) orelse return;
            const accel_config: *LibinputAccelConfig = @ptrCast(@alignCast(args.config.getUserData()));
            const config = accel_config.libinput orelse {
                _ = result.send(c.LIBINPUT_CONFIG_STATUS_INVALID);
                return;
            };
            const status = c.libinput_device_config_accel_apply(device.libinput, config);
            if (result.send(status)) {
                const current = c.libinput_device_config_accel_get_profile(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendAccelProfileCurrent(@enumFromInt(current));
            }
        },
        .set_natural_scroll => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_scroll_set_natural_scroll_enabled(device.libinput, switch (args.state) {
                .disabled => 0,
                .enabled => 1,
                _ => {
                    object.postError(.invalid_arg, "invalid natural_scroll_state enum value");
                    return;
                },
            });
            if (result.send(status)) {
                const current = c.libinput_device_config_scroll_get_natural_scroll_enabled(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendNaturalScrollCurrent(if (current != 0) .enabled else .disabled);
            }
        },
        .set_left_handed => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_left_handed_set(device.libinput, switch (args.state) {
                .disabled => 0,
                .enabled => 1,
                _ => {
                    object.postError(.invalid_arg, "invalid left_handed_state enum value");
                    return;
                },
            });
            if (result.send(status)) {
                const current = c.libinput_device_config_left_handed_get(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendLeftHandedCurrent(if (current != 0) .enabled else .disabled);
            }
        },
        .set_click_method => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_click_set_method(device.libinput, switch (args.method) {
                .none => c.LIBINPUT_CONFIG_CLICK_METHOD_NONE,
                .button_areas => c.LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS,
                .clickfinger => c.LIBINPUT_CONFIG_CLICK_METHOD_CLICKFINGER,
                _ => {
                    object.postError(.invalid_arg, "invalid click_method enum value");
                    return;
                },
            });
            if (result.send(status)) {
                const current = c.libinput_device_config_click_get_method(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendClickMethodCurrent(@enumFromInt(current));
            }
        },
        .set_clickfinger_button_map => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_click_set_clickfinger_button_map(device.libinput, switch (args.button_map) {
                .lrm => c.LIBINPUT_CONFIG_CLICKFINGER_MAP_LRM,
                .lmr => c.LIBINPUT_CONFIG_CLICKFINGER_MAP_LMR,
                _ => {
                    object.postError(.invalid_arg, "invalid clickfinger_button_map enum value");
                    return;
                },
            });
            if (result.send(status)) {
                const current = c.libinput_device_config_click_get_clickfinger_button_map(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendClickfingerButtonMapCurrent(@enumFromInt(current));
            }
        },
        .set_middle_emulation => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_middle_emulation_set_enabled(device.libinput, switch (args.state) {
                .disabled => c.LIBINPUT_CONFIG_MIDDLE_EMULATION_DISABLED,
                .enabled => c.LIBINPUT_CONFIG_MIDDLE_EMULATION_ENABLED,
                _ => {
                    object.postError(.invalid_arg, "invalid middle_emulation_state enum value");
                    return;
                },
            });
            if (result.send(status)) {
                const current = c.libinput_device_config_middle_emulation_get_enabled(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendMiddleEmulationCurrent(@enumFromInt(current));
            }
        },
        .set_scroll_method => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_scroll_set_method(device.libinput, switch (args.method) {
                .no_scroll => c.LIBINPUT_CONFIG_SCROLL_NO_SCROLL,
                .two_finger => c.LIBINPUT_CONFIG_SCROLL_2FG,
                .edge => c.LIBINPUT_CONFIG_SCROLL_EDGE,
                .on_button_down => c.LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN,
                _ => {
                    object.postError(.invalid_arg, "invalid scroll_method enum value");
                    return;
                },
            });
            if (result.send(status)) {
                const current = c.libinput_device_config_scroll_get_method(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendScrollMethodCurrent(@enumFromInt(current));
            }
        },
        .set_scroll_button => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_scroll_set_button(device.libinput, args.button);
            if (result.send(status)) {
                const current = c.libinput_device_config_scroll_get_button(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendScrollButtonCurrent(current);
            }
        },
        .set_scroll_button_lock => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_scroll_set_button_lock(device.libinput, switch (args.state) {
                .disabled => c.LIBINPUT_CONFIG_SCROLL_BUTTON_LOCK_DISABLED,
                .enabled => c.LIBINPUT_CONFIG_SCROLL_BUTTON_LOCK_ENABLED,
                _ => {
                    object.postError(.invalid_arg, "invalid scroll_button_lock_state enum value");
                    return;
                },
            });
            if (result.send(status)) {
                const current = c.libinput_device_config_scroll_get_button_lock(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendScrollButtonLockCurrent(@enumFromInt(current));
            }
        },
        .set_dwt => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_dwt_set_enabled(device.libinput, switch (args.state) {
                .disabled => c.LIBINPUT_CONFIG_DWT_DISABLED,
                .enabled => c.LIBINPUT_CONFIG_DWT_ENABLED,
                _ => {
                    object.postError(.invalid_arg, "invalid dwt_state enum value");
                    return;
                },
            });
            if (result.send(status)) {
                const current = c.libinput_device_config_dwt_get_enabled(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendDwtCurrent(if (current != 0) .enabled else .disabled);
            }
        },
        .set_dwtp => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_dwtp_set_enabled(device.libinput, switch (args.state) {
                .disabled => c.LIBINPUT_CONFIG_DWTP_DISABLED,
                .enabled => c.LIBINPUT_CONFIG_DWTP_ENABLED,
                _ => {
                    object.postError(.invalid_arg, "invalid dwtp_state enum value");
                    return;
                },
            });
            if (result.send(status)) {
                const current = c.libinput_device_config_dwtp_get_enabled(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendDwtpCurrent(if (current != 0) .enabled else .disabled);
            }
        },
        .set_rotation => |args| {
            const result = Result.create(object, args.result) orelse return;
            const status = c.libinput_device_config_rotation_set_angle(device.libinput, args.angle);
            if (result.send(status)) {
                const current = c.libinput_device_config_rotation_get_angle(device.libinput);
                var it = device.objects.iterator(.forward);
                while (it.next()) |o| o.sendRotationCurrent(current);
            }
        },
    }
}

const Result = struct {
    object: *river.LibinputResultV1,

    pub fn create(object: *river.LibinputDeviceV1, id: u32) ?Result {
        const result = river.LibinputResultV1.create(object.getClient(), object.getVersion(), id) catch {
            log.err("out of memory", .{});
            object.postNoMemory();
            return null;
        };
        return .{ .object = result };
    }

    pub fn send(result: *const Result, status: u32) bool {
        switch (status) {
            c.LIBINPUT_CONFIG_STATUS_SUCCESS => result.object.destroySendSuccess(),
            c.LIBINPUT_CONFIG_STATUS_UNSUPPORTED => result.object.destroySendUnsupported(),
            else => result.object.destroySendInvalid(),
        }
        return status == c.LIBINPUT_CONFIG_STATUS_SUCCESS;
    }
};
