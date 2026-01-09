// SPDX-FileCopyrightText: © 2022 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const InputDevice = @This();

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;

const c = @import("c.zig").c;
const server = &@import("main.zig").server;
const util = @import("util.zig");

const Keyboard = @import("Keyboard.zig");
const LibinputDevice = @import("LibinputDevice.zig");
const Seat = @import("Seat.zig");
const Tablet = @import("Tablet.zig");
const XkbKeyboard = @import("XkbKeyboard.zig");

const log = std.log.scoped(.input);

seat: *Seat,
wlr_device: *wlr.InputDevice,
virtual: bool,
objects: wl.list.Head(river.InputDeviceV1, null),

libinput: LibinputDevice,
xkb_keyboard: XkbKeyboard,

remove: wl.Listener(*wlr.InputDevice) = .init(handleRemove),

config: struct {
    scroll_factor: f64 = 1.0,
    map_to_output: ?*wlr.Output = null,
    map_to_rectangle: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
} = .{},

/// InputManager.devices
link: wl.list.Link,

pub fn init(
    device: *InputDevice,
    seat: *Seat,
    wlr_device: *wlr.InputDevice,
    virtual: bool,
) !void {
    device.* = .{
        .seat = seat,
        .wlr_device = wlr_device,
        .virtual = virtual,
        .libinput = undefined,
        .xkb_keyboard = undefined,
        .objects = undefined,
        .link = undefined,
    };
    device.objects.init();
    server.input_manager.devices.append(device);

    wlr_device.data = device;
    wlr_device.events.destroy.add(&device.remove);

    log.debug("new {s}input device: {s}-{s}", .{
        if (virtual) "virtual " else "",
        @tagName(wlr_device.type),
        wlr_device.name orelse "unknown",
    });

    if (!virtual) {
        var it = server.input_manager.objects.safeIterator(.forward);
        while (it.next()) |im_v1| {
            device.createObject(im_v1);
        }
        if (wlr_device.getLibinputDevice()) |handle| {
            device.libinput.init(@ptrCast(handle));
        }
    }

    // The wlroots Wayland and X11 backends support multiple outputs
    // exposed as multiple windows in the host session. However, this
    // requires mapping pointer/touch devices to the outputs suggested
    // by the backend to make input work as expected.
    if (switch (wlr_device.type) {
        .pointer => wlr_device.toPointer().output_name,
        .touch => wlr_device.toTouch().output_name,
        else => null,
    }) |output_name| {
        var it = server.om.outputs.iterator(.forward);
        while (it.next()) |output| {
            const wlr_output = output.wlr_output orelse continue;
            if (mem.orderZ(u8, output_name, wlr_output.name) == .eq) {
                device.config.map_to_output = wlr_output;
                break;
            }
        }
    }
    if (wlr_device.type == .keyboard) {
        device.xkb_keyboard.init();
    }
}

pub fn createObject(device: *InputDevice, im_v1: *river.InputManagerV1) void {
    assert(!device.virtual);
    const device_type: river.InputDeviceV1.Type = switch (device.wlr_device.type) {
        .keyboard => .keyboard,
        .pointer => .pointer,
        .touch => .touch,
        .tablet => .tablet,
        .@"switch", .tablet_pad => return,
    };
    const object = river.InputDeviceV1.create(im_v1.getClient(), im_v1.getVersion(), 0) catch {
        log.err("out of memory", .{});
        im_v1.postNoMemory();
        return;
    };
    im_v1.sendInputDevice(object);
    device.objects.append(object);
    object.setHandler(*InputDevice, handleRequest, handleDestroy, device);
    object.sendType(device_type);
    object.sendName(device.wlr_device.name orelse "");
}

pub fn deinit(device: *InputDevice) void {
    assert(device.objects.empty());
    device.remove.link.remove();

    if (device.wlr_device.getLibinputDevice() != null) {
        device.libinput.deinit();
    }
    if (device.wlr_device.type == .keyboard) {
        device.xkb_keyboard.deinit();
    }

    device.link.remove();
    device.seat.updateCapabilities();

    device.wlr_device.data = null;

    device.* = undefined;
}

pub fn assignToSeat(device: *InputDevice, new: *Seat) void {
    const old = device.seat;
    if (new == old) return;
    old.detachDevice(device);
    new.attachDevice(device);
    old.updateCapabilities();
    new.updateCapabilities();
}

fn handleRemove(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    const device: *InputDevice = @fieldParentPtr("remove", listener);

    log.debug("removed input device: {s}-{s}", .{
        @tagName(device.wlr_device.type),
        device.wlr_device.name orelse "unknown",
    });

    {
        var it = device.objects.iterator(.forward);
        while (it.next()) |object| {
            object.getLink().remove();
            object.sendRemoved();
            object.setHandler(?*anyopaque, handleRequestInert, null, null);
        }
    }

    switch (device.wlr_device.type) {
        .keyboard => {
            const keyboard: *Keyboard = @fieldParentPtr("device", device);
            keyboard.deviceDestroy();
        },
        .pointer, .touch => {
            device.deinit();
            util.gpa.destroy(device);
        },
        .tablet => {
            const tablet: *Tablet = @fieldParentPtr("device", device);
            tablet.destroy();
        },
        .@"switch", .tablet_pad => unreachable,
    }
}

fn handleRequestInert(
    object: *river.InputDeviceV1,
    request: river.InputDeviceV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) object.destroy();
}

fn handleDestroy(object: *river.InputDeviceV1, _: *InputDevice) void {
    object.getLink().remove();
}

fn handleRequest(
    object: *river.InputDeviceV1,
    request: river.InputDeviceV1.Request,
    device: *InputDevice,
) void {
    switch (request) {
        .destroy => object.destroy(),
        .assign_to_seat => |args| {
            var it = server.input_manager.seats.iterator(.forward);
            while (it.next()) |seat| {
                if (mem.orderZ(u8, args.name, seat.wlr_seat.name) == .eq) {
                    device.assignToSeat(seat);
                }
            }
            log.info("client requested input device be assigned to non-existant seat '{s}'", .{args.name});
        },
        .set_repeat_info => |args| {
            if (args.rate < 0 or args.delay < 0) {
                object.postError(.invalid_repeat_info, "negative rate/delay");
                return;
            }
            if (device.wlr_device.type == .keyboard) {
                const keyboard: *Keyboard = @fieldParentPtr("device", device);
                keyboard.setRepeatInfo(@intCast(args.rate), @intCast(args.delay));
            }
        },
        .set_scroll_factor => |args| {
            const factor = args.factor.toDouble();
            if (factor < 0) {
                object.postError(.invalid_scroll_factor, "negative scroll factor");
                return;
            }
            device.config.scroll_factor = factor;
        },
        .map_to_output => |args| {
            switch (device.wlr_device.type) {
                .pointer, .touch, .tablet => {},
                .keyboard, .@"switch", .tablet_pad => return,
            }
            if (args.output) |output| {
                device.config.map_to_output = wlr.Output.fromWlOutput(output) orelse return;
            } else {
                device.config.map_to_output = null;
            }
            device.seat.cursor.wlr_cursor.mapInputToOutput(
                device.wlr_device,
                device.config.map_to_output,
            );
        },
        .map_to_rectangle => |args| {
            if (args.width < 0 or args.height < 0) {
                object.postError(.invalid_map_to_rectangle, "negative rectangle width/height");
                return;
            }
            switch (device.wlr_device.type) {
                .pointer, .touch, .tablet => {},
                .keyboard, .@"switch", .tablet_pad => return,
            }
            device.config.map_to_rectangle = .{
                .x = args.x,
                .y = args.y,
                .width = args.width,
                .height = args.height,
            };
            device.seat.cursor.wlr_cursor.mapInputToRegion(
                device.wlr_device,
                &device.config.map_to_rectangle,
            );
        },
    }
}
