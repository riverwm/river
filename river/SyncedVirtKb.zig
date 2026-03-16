// SPDX-FileCopyrightText: © 2026 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const SyncedVirtKb = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const InputDevice = @import("InputDevice.zig");
const Seat = @import("Seat.zig");

const log = std.log.scoped(.input);

seat: *Seat,
/// Null if destroyed.
wlr_virt_kb: ?*wlr.VirtualKeyboardV1,

/// Number of events for this keyboard in seat.synced_virt_kb_queue
queued_events: u32 = 0,

/// Post-queue keyboard state.
state: wlr.Keyboard,

wlr_virt_kb_destroy: wl.Listener(*wlr.InputDevice) = .init(handleDestroy),

queue_key: wl.Listener(*wlr.Keyboard.event.Key) = .init(queueKey),
queue_modifiers: wl.Listener(*wlr.Keyboard) = .init(queueModifiers),
queue_keymap: wl.Listener(*wlr.Keyboard) = .init(queueKeymap),

process_key: wl.Listener(*wlr.Keyboard.event.Key) = .init(handleKey),
process_modifiers: wl.Listener(*wlr.Keyboard) = .init(handleModifiers),

/// Seat.synced_virt_kbs
link: wl.list.Link,

pub fn create(seat: *Seat, wlr_virt_kb: *wlr.VirtualKeyboardV1) !void {
    const synced_virt_kb = try util.gpa.create(SyncedVirtKb);
    errdefer util.gpa.destroy(synced_virt_kb);

    synced_virt_kb.* = .{
        .seat = seat,
        .wlr_virt_kb = wlr_virt_kb,
        .state = undefined,
        .link = undefined,
    };

    synced_virt_kb.state.init(&.{
        .name = "river.SyncedVirtKb",
        .led_update = null,
    }, "river.SyncedVirtKb");
    if (wlr_virt_kb.keyboard.keymap) |keymap| {
        _ = synced_virt_kb.state.setKeymap(keymap);
    }

    seat.synced_virt_kbs.append(synced_virt_kb);

    wlr_virt_kb.keyboard.base.events.destroy.add(&synced_virt_kb.wlr_virt_kb_destroy);

    wlr_virt_kb.keyboard.events.key.add(&synced_virt_kb.queue_key);
    wlr_virt_kb.keyboard.events.modifiers.add(&synced_virt_kb.queue_modifiers);
    wlr_virt_kb.keyboard.events.keymap.add(&synced_virt_kb.queue_keymap);

    synced_virt_kb.state.events.key.add(&synced_virt_kb.process_key);
    synced_virt_kb.state.events.modifiers.add(&synced_virt_kb.process_modifiers);
}

pub fn destroy(synced_virt_kb: *SyncedVirtKb) void {
    assert(synced_virt_kb.queued_events == 0);

    // If the currently active keyboard of a seat is destroyed we need to set
    // a new active keyboard. Otherwise wlroots may send an enter event without
    // first having sent a keymap event if Seat.keyboardNotifyEnter() is called
    // before a new active keyboard is set.
    if (synced_virt_kb.seat.wlr_seat.getKeyboard() == &synced_virt_kb.state) {
        if (synced_virt_kb.seat.keyboard_groups.first()) |other| {
            synced_virt_kb.seat.wlr_seat.setKeyboard(&other.state);
        }
    }

    synced_virt_kb.process_key.link.remove();
    synced_virt_kb.process_modifiers.link.remove();
    synced_virt_kb.state.finish();

    synced_virt_kb.link.remove();

    util.gpa.destroy(synced_virt_kb);
}

fn maybeDestroy(synced_virt_kb: *SyncedVirtKb) void {
    if (synced_virt_kb.wlr_virt_kb != null or synced_virt_kb.queued_events > 0) {
        return;
    }
    synced_virt_kb.destroy();
}

fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    const synced_virt_kb: *SyncedVirtKb = @fieldParentPtr("wlr_virt_kb_destroy", listener);
    synced_virt_kb.wlr_virt_kb = null;

    synced_virt_kb.wlr_virt_kb_destroy.link.remove();
    synced_virt_kb.queue_key.link.remove();
    synced_virt_kb.queue_modifiers.link.remove();
    synced_virt_kb.queue_keymap.link.remove();
}

fn queueKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
    const synced_virt_kb: *SyncedVirtKb = @fieldParentPtr("queue_key", listener);
    synced_virt_kb.seat.synced_virt_kb_queue.pushBackBounded(.{
        .synced_virt_kb = synced_virt_kb,
        .data = .{ .key = event.* },
    }) catch {
        log.err("synced virtual keyboard event queue full, dropping event", .{});
        return;
    };
    synced_virt_kb.queued_events += 1;
}

fn queueModifiers(listener: *wl.Listener(*wlr.Keyboard), _: *wlr.Keyboard) void {
    const synced_virt_kb: *SyncedVirtKb = @fieldParentPtr("queue_modifiers", listener);
    synced_virt_kb.seat.synced_virt_kb_queue.pushBackBounded(.{
        .synced_virt_kb = synced_virt_kb,
        .data = .{ .modifiers = synced_virt_kb.wlr_virt_kb.?.keyboard.modifiers },
    }) catch {
        log.err("synced virtual keyboard event queue full, dropping event", .{});
        return;
    };
    synced_virt_kb.queued_events += 1;
}

fn queueKeymap(listener: *wl.Listener(*wlr.Keyboard), _: *wlr.Keyboard) void {
    const synced_virt_kb: *SyncedVirtKb = @fieldParentPtr("queue_keymap", listener);
    const keymap = synced_virt_kb.wlr_virt_kb.?.keyboard.keymap orelse return;
    synced_virt_kb.seat.synced_virt_kb_queue.pushBackBounded(.{
        .synced_virt_kb = synced_virt_kb,
        .data = .{ .keymap = keymap.ref() },
    }) catch {
        log.err("synced virtual keyboard event queue full, dropping event", .{});
        keymap.unref();
        return;
    };
    synced_virt_kb.queued_events += 1;
}

pub fn dropEvent(synced_virt_kb: *SyncedVirtKb) void {
    synced_virt_kb.queued_events -= 1;
    synced_virt_kb.maybeDestroy();
}

pub fn processKey(synced_virt_kb: *SyncedVirtKb, key: *const wlr.Keyboard.event.Key) void {
    var key_copy = key.*;
    synced_virt_kb.state.notifyKey(&key_copy);
    synced_virt_kb.dropEvent();
}

pub fn processModifiers(synced_virt_kb: *SyncedVirtKb, modifiers: wlr.Keyboard.Modifiers) void {
    synced_virt_kb.state.notifyModifiers(modifiers);
    synced_virt_kb.dropEvent();
}

pub fn processKeymap(synced_virt_kb: *SyncedVirtKb, keymap: *xkb.Keymap) void {
    defer keymap.unref();
    _ = synced_virt_kb.state.setKeymap(keymap);
    synced_virt_kb.dropEvent();
}

fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
    const synced_virt_kb: *SyncedVirtKb = @fieldParentPtr("process_key", listener);
    synced_virt_kb.seat.wlr_seat.setKeyboard(&synced_virt_kb.state);
    synced_virt_kb.seat.wlr_seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
}

fn handleModifiers(listener: *wl.Listener(*wlr.Keyboard), _: *wlr.Keyboard) void {
    const synced_virt_kb: *SyncedVirtKb = @fieldParentPtr("process_modifiers", listener);
    synced_virt_kb.seat.wlr_seat.setKeyboard(&synced_virt_kb.state);
    synced_virt_kb.seat.wlr_seat.keyboardNotifyModifiers(&synced_virt_kb.state.modifiers);
}
