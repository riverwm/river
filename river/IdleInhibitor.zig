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

listen_destroy: wl.Listener(*wlr.Surface) = .init(handleDestroy),

link: wl.list.Link,

pub fn create(wlr_inhibitor: *wlr.IdleInhibitorV1, inhibit_manager: *IdleInhibitManager) !void {
    const inhibitor = try util.gpa.create(IdleInhibitor);
    errdefer util.gpa.destroy(inhibitor);

    inhibitor.* = .{
        .inhibit_manager = inhibit_manager,
        .wlr_inhibitor = wlr_inhibitor,
        .link = undefined,
    };
    wlr_inhibitor.events.destroy.add(&inhibitor.listen_destroy);

    inhibit_manager.inhibitors.append(inhibitor);

    inhibit_manager.checkActive();
}

pub fn destroy(inhibitor: *IdleInhibitor) void {
    inhibitor.listen_destroy.link.remove();

    inhibitor.link.remove();

    inhibitor.inhibit_manager.checkActive();

    util.gpa.destroy(inhibitor);
}

fn handleDestroy(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const inhibitor: *IdleInhibitor = @fieldParentPtr("listen_destroy", listener);

    inhibitor.destroy();
}
