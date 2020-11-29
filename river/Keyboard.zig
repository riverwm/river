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

const Self = @This();

const std = @import("std");

const c = @import("c.zig");
const log = @import("log.zig");
const util = @import("util.zig");

const Seat = @import("Seat.zig");

seat: *Seat,
wlr_input_device: *c.wlr_input_device,
wlr_keyboard: *c.wlr_keyboard,

listen_key: c.wl_listener = undefined,
listen_modifiers: c.wl_listener = undefined,
listen_destroy: c.wl_listener = undefined,

pub fn init(self: *Self, seat: *Seat, wlr_input_device: *c.wlr_input_device) !void {
    self.* = .{
        .seat = seat,
        .wlr_input_device = wlr_input_device,
        .wlr_keyboard = @field(wlr_input_device, c.wlr_input_device_union).keyboard,
    };

    // We need to prepare an XKB keymap and assign it to the keyboard. This
    // assumes the defaults (e.g. layout = "us").
    const rules = c.xkb_rule_names{
        .rules = null,
        .model = null,
        .layout = null,
        .variant = null,
        .options = null,
    };
    const context = c.xkb_context_new(.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbContextFailed;
    defer c.xkb_context_unref(context);

    const keymap = c.xkb_keymap_new_from_names(
        context,
        &rules,
        .XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return error.XkbKeymapFailed;
    defer c.xkb_keymap_unref(keymap);

    if (!c.wlr_keyboard_set_keymap(self.wlr_keyboard, keymap)) return error.SetKeymapFailed;
    c.wlr_keyboard_set_repeat_info(self.wlr_keyboard, 25, 600);

    // Setup listeners for keyboard events
    self.listen_key.notify = handleKey;
    c.wl_signal_add(&self.wlr_keyboard.events.key, &self.listen_key);

    self.listen_modifiers.notify = handleModifiers;
    c.wl_signal_add(&self.wlr_keyboard.events.modifiers, &self.listen_modifiers);

    self.listen_destroy.notify = handleDestroy;
    c.wl_signal_add(&self.wlr_keyboard.events.destroy, &self.listen_destroy);
}

pub fn deinit(self: *Self) void {
    c.wl_list_remove(&self.listen_key.link);
    c.wl_list_remove(&self.listen_modifiers.link);
    c.wl_list_remove(&self.listen_destroy.link);
}

fn handleKey(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is raised when a key is pressed or released.
    const self = @fieldParentPtr(Self, "listen_key", listener.?);
    const event = util.voidCast(c.wlr_event_keyboard_key, data.?);
    const wlr_keyboard = self.wlr_keyboard;

    self.seat.handleActivity();

    // Translate libinput keycode -> xkbcommon
    const keycode = event.keycode + 8;

    // Get a list of keysyms as xkb reports them
    var translated_keysyms: ?[*]c.xkb_keysym_t = undefined;
    const translated_keysyms_len = c.xkb_state_key_get_syms(
        wlr_keyboard.xkb_state,
        keycode,
        &translated_keysyms,
    );

    // Get a list of keysyms ignoring modifiers (e.g. 1 instead of !)
    // Important for mappings like Mod+Shift+1
    var raw_keysyms: ?[*]c.xkb_keysym_t = undefined;
    const layout_index = c.xkb_state_key_get_layout(wlr_keyboard.xkb_state, keycode);
    const raw_keysyms_len = c.xkb_keymap_key_get_syms_by_level(
        wlr_keyboard.keymap,
        keycode,
        layout_index,
        0,
        &raw_keysyms,
    );

    var handled = false;
    // TODO: These modifiers aren't properly handled, see sway's code
    const modifiers = c.wlr_keyboard_get_modifiers(wlr_keyboard);
    const released = event.state == .WLR_KEY_RELEASED;

    var i: usize = 0;
    while (i < translated_keysyms_len) : (i += 1) {
        // Handle builtin mapping only when keys are pressed
        if (!released and self.handleBuiltinMapping(translated_keysyms.?[i])) {
            handled = true;
            break;
        } else if (self.seat.handleMapping(translated_keysyms.?[i], modifiers, released)) {
            handled = true;
            break;
        }
    }
    if (!handled) {
        i = 0;
        while (i < raw_keysyms_len) : (i += 1) {
            // Handle builtin mapping only when keys are pressed
            if (!released and self.handleBuiltinMapping(raw_keysyms.?[i])) {
                handled = true;
                break;
            } else if (self.seat.handleMapping(raw_keysyms.?[i], modifiers, released)) {
                handled = true;
                break;
            }
        }
    }

    if (!handled) {
        // Otherwise, we pass it along to the client.
        const wlr_seat = self.seat.wlr_seat;
        c.wlr_seat_set_keyboard(wlr_seat, self.wlr_input_device);
        c.wlr_seat_keyboard_notify_key(
            wlr_seat,
            event.time_msec,
            event.keycode,
            @intCast(u32, @enumToInt(event.state)),
        );
    }
}

fn handleModifiers(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is raised when a modifier key, such as shift or alt, is
    // pressed. We simply communicate this to the client. */
    const self = @fieldParentPtr(Self, "listen_modifiers", listener.?);

    // A seat can only have one keyboard, but this is a limitation of the
    // Wayland protocol - not wlroots. We assign all connected keyboards to the
    // same seat. You can swap out the underlying wlr_keyboard like this and
    // wlr_seat handles this transparently.
    c.wlr_seat_set_keyboard(self.seat.wlr_seat, self.wlr_input_device);

    // Send modifiers to the client.
    c.wlr_seat_keyboard_notify_modifiers(self.seat.wlr_seat, &self.wlr_keyboard.modifiers);
}
fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_destroy", listener.?);
    self.deinit();
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    self.seat.keyboards.remove(node);
    util.gpa.destroy(node);
}

/// Handle any builtin, harcoded compsitor mappings such as VT switching.
/// Returns true if the keysym was handled.
fn handleBuiltinMapping(self: Self, keysym: c.xkb_keysym_t) bool {
    if (keysym >= c.XKB_KEY_XF86Switch_VT_1 and keysym <= c.XKB_KEY_XF86Switch_VT_12) {
        log.debug(.keyboard, "switch VT keysym received", .{});
        const wlr_backend = self.seat.input_manager.server.wlr_backend;
        if (c.wlr_backend_is_multi(wlr_backend)) {
            if (c.wlr_backend_get_session(wlr_backend)) |session| {
                const vt = keysym - c.XKB_KEY_XF86Switch_VT_1 + 1;
                log.notice(.server, "switching to VT {}", .{vt});
                _ = c.wlr_session_change_vt(session, vt);
            }
        }
        return true;
    }
    return false;
}
