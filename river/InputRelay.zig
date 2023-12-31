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
/// The currently enabled text input for the currently focused surface.
text_input: ?*TextInput = null,

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
    assert(input_method == self.input_method);

    if (!input_method.client_active) return;
    const text_input = self.text_input orelse return;

    if (input_method.current.preedit.text) |preedit_text| {
        text_input.wlr_text_input.sendPreeditString(
            preedit_text,
            input_method.current.preedit.cursor_begin,
            input_method.current.preedit.cursor_end,
        );
    }

    if (input_method.current.commit_text) |commit_text| {
        text_input.wlr_text_input.sendCommitString(commit_text);
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

fn handleInputMethodDestroy(
    listener: *wl.Listener(*wlr.InputMethodV2),
    input_method: *wlr.InputMethodV2,
) void {
    const self = @fieldParentPtr(Self, "input_method_destroy", listener);
    assert(input_method == self.input_method);

    self.input_method_commit.link.remove();
    self.grab_keyboard.link.remove();
    self.input_method_destroy.link.remove();

    self.input_method = null;

    self.focus(null);
}

fn handleInputMethodGrabKeyboard(
    listener: *wl.Listener(*wlr.InputMethodV2.KeyboardGrab),
    keyboard_grab: *wlr.InputMethodV2.KeyboardGrab,
) void {
    const self = @fieldParentPtr(Self, "grab_keyboard", listener);

    const active_keyboard = self.seat.wlr_seat.getKeyboard();
    keyboard_grab.setKeyboard(active_keyboard);

    keyboard_grab.events.destroy.add(&self.grab_keyboard_destroy);
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

pub fn disableTextInput(self: *Self) void {
    assert(self.text_input != null);

    if (self.input_method) |input_method| {
        input_method.sendDeactivate();
        input_method.sendDone();
    }

    self.text_input = null;
}

pub fn sendInputMethodState(self: *Self) void {
    const input_method = self.input_method.?;
    const wlr_text_input = self.text_input.?.wlr_text_input;

    // TODO Send these events only if something changed.
    // On activation all events must be sent for all active features.

    if (wlr_text_input.active_features.surrounding_text) {
        if (wlr_text_input.current.surrounding.text) |text| {
            input_method.sendSurroundingText(
                text,
                wlr_text_input.current.surrounding.cursor,
                wlr_text_input.current.surrounding.anchor,
            );
        }
    }

    input_method.sendTextChangeCause(wlr_text_input.current.text_change_cause);

    if (wlr_text_input.active_features.content_type) {
        input_method.sendContentType(
            wlr_text_input.current.content_type.hint,
            wlr_text_input.current.content_type.purpose,
        );
    }

    input_method.sendDone();
}

pub fn focus(self: *Self, new_focus: ?*wlr.Surface) void {
    // Send leave events
    {
        var it = self.text_inputs.first;
        while (it) |node| : (it = node.next) {
            const text_input = &node.data;

            if (text_input.wlr_text_input.focused_surface) |surface| {
                // This function should not be called unless focus changes
                assert(surface != new_focus);
                text_input.wlr_text_input.sendLeave();
            }
        }
    }

    // Clear currently enabled text input
    if (self.text_input != null) {
        self.disableTextInput();
    }

    // Send enter events if we have an input method.
    // No text input for the new surface should be enabled yet as the client
    // should wait until it receives an enter event.
    if (new_focus) |surface| {
        if (self.input_method != null) {
            var it = self.text_inputs.first;
            while (it) |node| : (it = node.next) {
                const text_input = &node.data;

                if (text_input.wlr_text_input.resource.getClient() == surface.resource.getClient()) {
                    text_input.wlr_text_input.sendEnter(surface);
                }
            }
        }
    }
}
