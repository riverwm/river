// SPDX-FileCopyrightText: © 2022 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

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
