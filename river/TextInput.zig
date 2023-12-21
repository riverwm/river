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

/// Surface stored for when text-input can't receive an enter event immediately
/// after getting focus. Cleared once text-input receive the enter event.
pending_focused_surface: ?*wlr.Surface = null,

enable: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleEnable),
commit: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleCommit),
disable: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleDisable),
destroy: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleDestroy),

pending_focused_surface_destroy: wl.Listener(*wlr.Surface) =
    wl.Listener(*wlr.Surface).init(handlePendingFocusedSurfaceDestroy),

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

    if (self.relay.input_method) |im| {
        im.sendActivate();
    } else {
        log.debug("enabling text input but input method is gone", .{});
        return;
    }

    // must send surrounding_text if supported
    // must send content_type if supported
    self.relay.sendInputMethodState(self.wlr_text_input);
}

fn handleCommit(listener: *wl.Listener(*wlr.TextInputV3), _: *wlr.TextInputV3) void {
    const self = @fieldParentPtr(Self, "commit", listener);
    if (!self.wlr_text_input.current_enabled) {
        log.debug("inactive text input tried to commit an update", .{});
        return;
    }
    log.debug("text input committed update", .{});
    if (self.relay.input_method == null) {
        log.debug("committed text input but input method is gone", .{});
        return;
    }
    self.relay.sendInputMethodState(self.wlr_text_input);
}

fn handleDisable(listener: *wl.Listener(*wlr.TextInputV3), _: *wlr.TextInputV3) void {
    const self = @fieldParentPtr(Self, "disable", listener);
    if (self.wlr_text_input.focused_surface == null) {
        log.debug("disabling text input, but no longer focused", .{});
        return;
    }
    self.relay.disableTextInput(self);
}

fn handleDestroy(listener: *wl.Listener(*wlr.TextInputV3), _: *wlr.TextInputV3) void {
    const self = @fieldParentPtr(Self, "destroy", listener);
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);

    if (self.wlr_text_input.current_enabled) self.relay.disableTextInput(self);

    node.data.setPendingFocusedSurface(null);

    self.enable.link.remove();
    self.commit.link.remove();
    self.disable.link.remove();
    self.destroy.link.remove();

    self.relay.text_inputs.remove(node);
    util.gpa.destroy(node);
}

fn handlePendingFocusedSurfaceDestroy(listener: *wl.Listener(*wlr.Surface), surface: *wlr.Surface) void {
    const self = @fieldParentPtr(Self, "pending_focused_surface_destroy", listener);
    assert(self.pending_focused_surface == surface);
    self.pending_focused_surface = null;
    self.pending_focused_surface_destroy.link.remove();
}

pub fn setPendingFocusedSurface(self: *Self, wlr_surface: ?*wlr.Surface) void {
    if (self.pending_focused_surface != null) self.pending_focused_surface_destroy.link.remove();
    self.pending_focused_surface = wlr_surface;
    if (self.pending_focused_surface) |surface| {
        surface.events.destroy.add(&self.pending_focused_surface_destroy);
    }
}
