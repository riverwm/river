// SPDX-FileCopyrightText: © 2026 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const XkbKeyboard = @This();

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;
const xkb = @import("xkbcommon");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const InputDevice = @import("InputDevice.zig");
const Keyboard = @import("Keyboard.zig");
const XkbKeymap = @import("XkbKeymap.zig");

const log = std.log.scoped(.input);

objects: wl.list.Head(river.XkbKeyboardV1, null),

sent: struct {
    layout_index: ?u32 = null,
    /// This string is owned by our global xkb.Context.
    layout_name: ?[*:0]const u8 = null,
    capslock: ?bool = null,
    numlock: ?bool = null,
} = .{},

/// XkbConfig.keyboards
link: wl.list.Link,

pub fn init(xkb_keyboard: *XkbKeyboard) void {
    xkb_keyboard.* = .{
        .objects = undefined,
        .link = undefined,
    };
    xkb_keyboard.objects.init();
    server.xkb_config.keyboards.append(xkb_keyboard);
    {
        var it = server.xkb_config.objects.iterator(.forward);
        while (it.next()) |config_v1| xkb_keyboard.createObject(config_v1);
    }
}

pub fn createObject(xkb_keyboard: *XkbKeyboard, config_v1: *river.XkbConfigV1) void {
    const object = river.XkbKeyboardV1.create(config_v1.getClient(), config_v1.getVersion(), 0) catch {
        log.err("out of memory", .{});
        config_v1.postNoMemory();
        return;
    };
    xkb_keyboard.objects.append(object);
    object.setHandler(*XkbKeyboard, handleRequest, handleDestroy, xkb_keyboard);
    config_v1.sendXkbKeyboard(object);
    {
        const device: *InputDevice = @fieldParentPtr("xkb_keyboard", xkb_keyboard);
        var it = device.objects.iterator(.forward);
        while (it.next()) |input_device_v1| {
            if (object.getClient() == input_device_v1.getClient()) {
                object.sendInputDevice(input_device_v1);
            }
        }
    }
    const sent = &xkb_keyboard.sent;
    if (sent.layout_index) |layout_index| {
        object.sendLayout(layout_index, sent.layout_name);
    }
    if (sent.capslock) |capslock| {
        if (capslock) {
            object.sendCapslockEnabled();
        } else {
            object.sendCapslockDisabled();
        }
    }
    if (sent.numlock) |numlock| {
        if (numlock) {
            object.sendNumlockEnabled();
        } else {
            object.sendNumlockDisabled();
        }
    }
}

pub fn deinit(xkb_keyboard: *XkbKeyboard) void {
    {
        var it = xkb_keyboard.objects.iterator(.forward);
        while (it.next()) |object| {
            object.getLink().remove();
            object.sendRemoved();
            object.setHandler(?*anyopaque, handleRequestInert, null, null);
        }
    }
    assert(xkb_keyboard.objects.empty());
    xkb_keyboard.link.remove();
}

fn handleRequestInert(
    object: *river.XkbKeyboardV1,
    request: river.XkbKeyboardV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) object.destroy();
}

fn handleDestroy(object: *river.XkbKeyboardV1, _: *XkbKeyboard) void {
    object.getLink().remove();
}

fn handleRequest(
    object: *river.XkbKeyboardV1,
    request: river.XkbKeyboardV1.Request,
    xkb_keyboard: *XkbKeyboard,
) void {
    const device: *InputDevice = @fieldParentPtr("xkb_keyboard", xkb_keyboard);
    const keyboard: *Keyboard = @fieldParentPtr("device", device);
    const group = keyboard.group.?;
    switch (request) {
        .destroy => object.destroy(),
        .set_keymap => |args| {
            const keymap: ?*XkbKeymap = @ptrCast(@alignCast(args.keymap.getUserData()));
            if (keymap) |k| {
                keyboard.setKeymap(k.xkb_keymap);
            } else {
                object.postError(.invalid_keymap, "client set invalid keymap");
                return;
            }
        },
        .set_layout_by_index => |args| {
            if (args.index < 0 or args.index >= group.config.keymap.?.numLayouts()) return;
            var modifiers = group.state.modifiers;
            modifiers.group = @intCast(args.index);
            group.state.notifyModifiers(modifiers);
        },
        .set_layout_by_name => |args| {
            const index = group.config.keymap.?.layoutGetIndex(args.name);
            if (index == xkb.layout_invalid) return;
            var modifiers = group.state.modifiers;
            modifiers.group = index;
            group.state.notifyModifiers(modifiers);
        },
        .numlock_enable => {
            const mask = group.config.keymap.?.modGetMask(xkb.names.vmod.num);
            var modifiers = group.state.modifiers;
            modifiers.locked |= mask;
            group.state.notifyModifiers(modifiers);
        },
        .numlock_disable => {
            const mask = group.config.keymap.?.modGetMask(xkb.names.vmod.num);
            var modifiers = group.state.modifiers;
            modifiers.locked &= ~mask;
            group.state.notifyModifiers(modifiers);
        },
        .capslock_enable => {
            const mask = group.config.keymap.?.modGetMask(xkb.names.mod.caps);
            var modifiers = group.state.modifiers;
            modifiers.locked |= mask;
            group.state.notifyModifiers(modifiers);
        },
        .capslock_disable => {
            const mask = group.config.keymap.?.modGetMask(xkb.names.mod.caps);
            var modifiers = group.state.modifiers;
            modifiers.locked &= ~mask;
            group.state.notifyModifiers(modifiers);
        },
    }
}

pub fn sendState(
    xkb_keyboard: *XkbKeyboard,
    layout_index: xkb.LayoutIndex,
    layout_name: ?[*:0]const u8,
    capslock: bool,
    numlock: bool,
) void {
    const sent = &xkb_keyboard.sent;
    var it = xkb_keyboard.objects.iterator(.forward);
    while (it.next()) |object| {
        if (sent.layout_index != layout_index or
            (sent.layout_name == null) != (layout_name == null) or
            (layout_name != null and mem.orderZ(u8, layout_name.?, sent.layout_name.?) != .eq))
        {
            object.sendLayout(layout_index, layout_name);
        }
        if (sent.capslock != capslock) {
            if (capslock) {
                object.sendCapslockEnabled();
            } else {
                object.sendCapslockDisabled();
            }
        }
        if (sent.numlock != numlock) {
            if (numlock) {
                object.sendNumlockEnabled();
            } else {
                object.sendNumlockDisabled();
            }
        }
    }
    sent.layout_index = layout_index;
    sent.layout_name = layout_name;
    sent.capslock = capslock;
    sent.numlock = numlock;
}
