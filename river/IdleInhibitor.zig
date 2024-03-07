// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2022 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const IdleInhibitor = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const IdleInhibitManager = @import("IdleInhibitManager.zig");

inhibit_manager: *IdleInhibitManager,
wlr_inhibitor: *wlr.IdleInhibitorV1,

destroy: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleDestroy),

pub fn init(
    inhibitor: *IdleInhibitor,
    wlr_inhibitor: *wlr.IdleInhibitorV1,
    inhibit_manager: *IdleInhibitManager,
) !void {
    inhibitor.* = .{
        .inhibit_manager = inhibit_manager,
        .wlr_inhibitor = wlr_inhibitor,
    };
    wlr_inhibitor.events.destroy.add(&inhibitor.destroy);

    inhibit_manager.checkActive();
}

fn handleDestroy(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const inhibitor: *IdleInhibitor = @fieldParentPtr("destroy", listener);

    inhibitor.destroy.link.remove();

    const node: *std.TailQueue(IdleInhibitor).Node = @fieldParentPtr("data", inhibitor);
    server.idle_inhibit_manager.inhibitors.remove(node);

    inhibitor.inhibit_manager.checkActive();

    util.gpa.destroy(node);
}
