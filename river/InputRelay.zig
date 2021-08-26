// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 The River Developers
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
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const util = @import("util.zig");

const TextInput = @import("TextInput.zig");
const Seat = @import("Seat.zig");

const log = std.log.scoped(.input_relay);

/// The Relay structure manages the communication between text_inputs
/// and input_method on a given seat.
seat: *Seat,

/// List of all TextInput bound to the relay.
/// Multiple wlr_text_input interfaces can be bound to a relay,
/// but only one at a time can receive events.
text_inputs: std.TailQueue(TextInput) = .{},

input_method: ?*wlr.InputMethodV2 = null,

input_method_commit: wl.Listener(*wlr.InputMethodV2) =
    wl.Listener(*wlr.InputMethodV2).init(handleInputMethodCommit),
grab_keyboard: wl.Listener(*wlr.InputMethodV2.KeyboardGrab) =
    wl.Listener(*wlr.InputMethodV2.KeyboardGrab).init(handleInputMethodGrabKeyboard),
input_method_destroy: wl.Listener(*wlr.InputMethodV2) =
    wl.Listener(*wlr.InputMethodV2).init(handleInputMethodDestroy),

grab_keyboard_destroy: wl.Listener(*wlr.InputMethodV2.KeyboardGrab) =
    wl.Listener(*wlr.InputMethodV2.KeyboardGrab).init(handleInputMethodGrabKeyboardDestroy),

pub fn init(self: *Self, seat: *Seat) void {
    self.* = .{ .seat = seat };
}

fn handleInputMethodCommit(
    listener: *wl.Listener(*wlr.InputMethodV2),
    input_method: *wlr.InputMethodV2,
) void {
    const self = @fieldParentPtr(Self, "input_method_commit", listener);
    const text_input = self.getFocusedTextInput() orelse return;

    assert(input_method == self.input_method);

    if (mem.span(input_method.current.preedit.text).len != 0) {
        // This is needed because wlroots 0.14.1 use the wrong types as function args
        // see https://gitlab.freedesktop.org/wlroots/wlroots/-/merge_requests/3336
        @import("wayland").server.zwp.TextInputV3.sendPreeditString(
            @ptrCast(*@import("wayland").server.zwp.TextInputV3, text_input.wlr_text_input),
            input_method.current.preedit.text,
            input_method.current.preedit.cursor_begin,
            input_method.current.preedit.cursor_end,
        );
    }

    if (mem.span(input_method.current.commit_text).len != 0) {
        text_input.wlr_text_input.sendCommitString(input_method.current.commit_text);
    }

    if (input_method.current.delete.before_length != 0 or
        input_method.current.delete.after_length != 0)
    {
        text_input.wlr_text_input.sendDeleteSurroundingText(
            input_method.current.delete.before_length,
            input_method.current.delete.after_length,
        );
    }

    text_input.wlr_text_input.sendDone();
}

fn handleInputMethodGrabKeyboard(
    listener: *wl.Listener(*wlr.InputMethodV2.KeyboardGrab),
    keyboard_grab: *wlr.InputMethodV2.KeyboardGrab,
) void {
    const self = @fieldParentPtr(Self, "grab_keyboard", listener);

    const active_keyboard = self.seat.wlr_seat.getKeyboard() orelse return;
    keyboard_grab.setKeyboard(active_keyboard);
    keyboard_grab.sendModifiers(&active_keyboard.modifiers);

    keyboard_grab.events.destroy.add(&self.grab_keyboard_destroy);
}

fn handleInputMethodDestroy(
    listener: *wl.Listener(*wlr.InputMethodV2),
    input_method: *wlr.InputMethodV2,
) void {
    const self = @fieldParentPtr(Self, "input_method_destroy", listener);

    assert(input_method == self.input_method);
    self.input_method = null;

    const text_input = self.getFocusedTextInput() orelse return;
    if (text_input.wlr_text_input.focused_surface) |surface| {
        text_input.setPendingFocusedSurface(surface);
    }
    text_input.wlr_text_input.sendLeave();
}

fn handleInputMethodGrabKeyboardDestroy(
    listener: *wl.Listener(*wlr.InputMethodV2.KeyboardGrab),
    keyboard_grab: *wlr.InputMethodV2.KeyboardGrab,
) void {
    const self = @fieldParentPtr(Self, "grab_keyboard_destroy", listener);
    self.grab_keyboard_destroy.link.remove();

    if (keyboard_grab.keyboard) |keyboard| {
        keyboard_grab.input_method.seat.keyboardNotifyModifiers(&keyboard.modifiers);
    }
}

pub fn getFocusableTextInput(self: *Self) ?*TextInput {
    var it = self.text_inputs.first;
    return while (it) |node| : (it = node.next) {
        const text_input = &node.data;
        if (text_input.pending_focused_surface != null) break text_input;
    } else null;
}

pub fn getFocusedTextInput(self: *Self) ?*TextInput {
    var it = self.text_inputs.first;
    return while (it) |node| : (it = node.next) {
        const text_input = &node.data;
        if (text_input.wlr_text_input.focused_surface != null) break text_input;
    } else null;
}

pub fn disableTextInput(self: *Self, text_input: *TextInput) void {
    if (self.input_method) |im| {
        im.sendDeactivate();
    } else {
        log.debug("disabling text input but input method is gone", .{});
        return;
    }

    self.sendInputMethodState(text_input.wlr_text_input);
}

pub fn sendInputMethodState(self: *Self, wlr_text_input: *wlr.TextInputV3) void {
    const input_method = self.input_method orelse return;

    if (wlr_text_input.active_features == wlr.TextInputV3.features.surrounding_text) {
        if (wlr_text_input.current.surrounding.text) |text| {
            input_method.sendSurroundingText(
                text,
                wlr_text_input.current.surrounding.cursor,
                wlr_text_input.current.surrounding.anchor,
            );
        }
    }

    input_method.sendTextChangeCause(wlr_text_input.current.text_change_cause);

    if (wlr_text_input.active_features == wlr.TextInputV3.features.content_type) {
        input_method.sendContentType(
            wlr_text_input.current.content_type.hint,
            wlr_text_input.current.content_type.purpose,
        );
    }

    input_method.sendDone();
}

/// Update the current focused surface. Surface must belong to the same seat.
pub fn setSurfaceFocus(self: *Self, wlr_surface: ?*wlr.Surface) void {
    var it = self.text_inputs.first;
    while (it) |node| : (it = node.next) {
        const text_input = &node.data;
        if (text_input.pending_focused_surface) |surface| {
            assert(text_input.wlr_text_input.focused_surface == null);
            if (wlr_surface != surface) {
                text_input.setPendingFocusedSurface(null);
            }
        } else if (text_input.wlr_text_input.focused_surface) |surface| {
            assert(text_input.pending_focused_surface == null);
            if (wlr_surface != surface) {
                text_input.relay.disableTextInput(text_input);
                text_input.wlr_text_input.sendLeave();
            } else {
                log.debug("IM relay setSurfaceFocus already focused", .{});
                continue;
            }
        }
        if (wlr_surface) |surface| {
            if (text_input.wlr_text_input.resource.getClient() == surface.resource.getClient()) {
                if (self.input_method != null) {
                    text_input.wlr_text_input.sendEnter(surface);
                } else {
                    text_input.setPendingFocusedSurface(surface);
                }
            }
        }
    }
}
