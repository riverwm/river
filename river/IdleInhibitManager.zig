// SPDX-FileCopyrightText: © 2022 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const IdleInhibitManager = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const IdleInhibitor = @import("IdleInhibitor.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Window = @import("Window.zig");

wlr_manager: *wlr.IdleInhibitManagerV1,
new_idle_inhibitor: wl.Listener(*wlr.IdleInhibitorV1) = .init(handleNewIdleInhibitor),
inhibitors: wl.list.Head(IdleInhibitor, .link),

pub fn init(inhibit_manager: *IdleInhibitManager) !void {
    inhibit_manager.* = .{
        .wlr_manager = try wlr.IdleInhibitManagerV1.create(server.wl_server),
        .inhibitors = undefined,
    };
    inhibit_manager.inhibitors.init();

    inhibit_manager.wlr_manager.events.new_inhibitor.add(&inhibit_manager.new_idle_inhibitor);
}

pub fn deinit(inhibit_manager: *IdleInhibitManager) void {
    while (inhibit_manager.inhibitors.first()) |inhibitor| {
        inhibitor.destroy();
    }
    inhibit_manager.new_idle_inhibitor.link.remove();
}

pub fn checkActive(inhibit_manager: *IdleInhibitManager) void {
    var inhibited = false;
    var it = inhibit_manager.inhibitors.iterator(.forward);
    while (it.next()) |inhibitor| {
        const node_data = SceneNodeData.fromSurface(inhibitor.wlr_inhibitor.surface) orelse continue;
        switch (node_data.data) {
            // TODO be stricter here so that clients don't abuse the protocol
            .window, .shell_surface, .lock_surface, .layer_surface, .override_redirect => {
                inhibited = true;
                break;
            },
        }
    }

    server.input_manager.idle_notifier.setInhibited(inhibited);
}

fn handleNewIdleInhibitor(listener: *wl.Listener(*wlr.IdleInhibitorV1), inhibitor: *wlr.IdleInhibitorV1) void {
    const inhibit_manager: *IdleInhibitManager = @fieldParentPtr("new_idle_inhibitor", listener);
    IdleInhibitor.create(inhibitor, inhibit_manager) catch {
        std.log.err("out of memory", .{});
        return;
    };
}
