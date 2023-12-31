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
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const util = @import("util.zig");

const InputRelay = @import("InputRelay.zig");
const Seat = @import("Seat.zig");

const log = std.log.scoped(.text_input);

relay: *InputRelay,
wlr_text_input: *wlr.TextInputV3,

enable: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleEnable),
commit: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleCommit),
disable: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleDisable),
destroy: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleDestroy),

pub fn init(self: *Self, relay: *InputRelay, wlr_text_input: *wlr.TextInputV3) void {
    self.* = .{
        .relay = relay,
        .wlr_text_input = wlr_text_input,
    };

    wlr_text_input.events.enable.add(&self.enable);
    wlr_text_input.events.commit.add(&self.commit);
    wlr_text_input.events.disable.add(&self.disable);
    wlr_text_input.events.destroy.add(&self.destroy);
}

fn handleEnable(listener: *wl.Listener(*wlr.TextInputV3), _: *wlr.TextInputV3) void {
    const self = @fieldParentPtr(Self, "enable", listener);

    if (self.relay.text_input != null) {
        log.err("client requested to enable more than one text input on a single seat, ignoring request", .{});
        return;
    }

    self.relay.text_input = self;

    if (self.relay.input_method) |input_method| {
        input_method.sendActivate();
        self.relay.sendInputMethodState();
    }
}

fn handleCommit(listener: *wl.Listener(*wlr.TextInputV3), _: *wlr.TextInputV3) void {
    const self = @fieldParentPtr(Self, "commit", listener);

    if (self.relay.text_input != self) {
        log.err("inactive text input tried to commit an update, client bug?", .{});
        return;
    }

    if (self.relay.input_method != null) {
        self.relay.sendInputMethodState();
    }
}

fn handleDisable(listener: *wl.Listener(*wlr.TextInputV3), _: *wlr.TextInputV3) void {
    const self = @fieldParentPtr(Self, "disable", listener);

    if (self.relay.text_input == self) {
        self.relay.disableTextInput();
    }
}

fn handleDestroy(listener: *wl.Listener(*wlr.TextInputV3), _: *wlr.TextInputV3) void {
    const self = @fieldParentPtr(Self, "destroy", listener);
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);

    if (self.relay.text_input == self) {
        self.relay.disableTextInput();
    }

    self.enable.link.remove();
    self.commit.link.remove();
    self.disable.link.remove();
    self.destroy.link.remove();

    self.relay.text_inputs.remove(node);
    util.gpa.destroy(node);
}
