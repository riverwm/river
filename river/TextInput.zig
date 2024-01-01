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

const TextInput = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const util = @import("util.zig");

const InputRelay = @import("InputRelay.zig");
const Seat = @import("Seat.zig");

const log = std.log.scoped(.text_input);

link: wl.list.Link,

wlr_text_input: *wlr.TextInputV3,

enable: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleEnable),
commit: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleCommit),
disable: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleDisable),
destroy: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleDestroy),

pub fn create(wlr_text_input: *wlr.TextInputV3) !void {
    const seat: *Seat = @ptrFromInt(wlr_text_input.seat.data);

    const text_input = try util.gpa.create(TextInput);

    log.debug("new text input on seat {s}", .{seat.wlr_seat.name});

    text_input.* = .{
        .link = undefined,
        .wlr_text_input = wlr_text_input,
    };

    seat.relay.text_inputs.append(text_input);

    wlr_text_input.events.enable.add(&text_input.enable);
    wlr_text_input.events.commit.add(&text_input.commit);
    wlr_text_input.events.disable.add(&text_input.disable);
    wlr_text_input.events.destroy.add(&text_input.destroy);
}

fn handleEnable(listener: *wl.Listener(*wlr.TextInputV3), _: *wlr.TextInputV3) void {
    const text_input = @fieldParentPtr(TextInput, "enable", listener);
    const seat: *Seat = @ptrFromInt(text_input.wlr_text_input.seat.data);

    // The same text_input object may be enabled multiple times consecutively
    // without first disabling it. Enabling a different text input object without
    // first disabling the current one is disallowed by the protocol however.
    if (seat.relay.text_input) |currently_enabled| {
        if (text_input != currently_enabled) {
            log.err("client requested to enable more than one text input on a single seat, ignoring request", .{});
            return;
        }
    }

    seat.relay.text_input = text_input;

    if (seat.relay.input_method) |input_method| {
        input_method.sendActivate();
        seat.relay.sendInputMethodState();
    }
}

fn handleCommit(listener: *wl.Listener(*wlr.TextInputV3), _: *wlr.TextInputV3) void {
    const text_input = @fieldParentPtr(TextInput, "commit", listener);
    const seat: *Seat = @ptrFromInt(text_input.wlr_text_input.seat.data);

    if (seat.relay.text_input != text_input) {
        log.err("inactive text input tried to commit an update, client bug?", .{});
        return;
    }

    if (seat.relay.input_method != null) {
        seat.relay.sendInputMethodState();
    }
}

fn handleDisable(listener: *wl.Listener(*wlr.TextInputV3), _: *wlr.TextInputV3) void {
    const text_input = @fieldParentPtr(TextInput, "disable", listener);
    const seat: *Seat = @ptrFromInt(text_input.wlr_text_input.seat.data);

    if (seat.relay.text_input == text_input) {
        seat.relay.disableTextInput();
    }
}

fn handleDestroy(listener: *wl.Listener(*wlr.TextInputV3), _: *wlr.TextInputV3) void {
    const text_input = @fieldParentPtr(TextInput, "destroy", listener);
    const seat: *Seat = @ptrFromInt(text_input.wlr_text_input.seat.data);

    if (seat.relay.text_input == text_input) {
        seat.relay.disableTextInput();
    }

    text_input.enable.link.remove();
    text_input.commit.link.remove();
    text_input.disable.link.remove();
    text_input.destroy.link.remove();

    text_input.link.remove();
    util.gpa.destroy(text_input);
}
