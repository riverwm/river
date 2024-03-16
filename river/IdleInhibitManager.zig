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

const IdleInhibitManager = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const IdleInhibitor = @import("IdleInhibitor.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const View = @import("View.zig");

wlr_manager: *wlr.IdleInhibitManagerV1,
new_idle_inhibitor: wl.Listener(*wlr.IdleInhibitorV1) =
    wl.Listener(*wlr.IdleInhibitorV1).init(handleNewIdleInhibitor),
inhibitors: std.TailQueue(IdleInhibitor) = .{},

pub fn init(inhibit_manager: *IdleInhibitManager) !void {
    inhibit_manager.* = .{
        .wlr_manager = try wlr.IdleInhibitManagerV1.create(server.wl_server),
    };
    inhibit_manager.wlr_manager.events.new_inhibitor.add(&inhibit_manager.new_idle_inhibitor);
}

pub fn deinit(inhibit_manager: *IdleInhibitManager) void {
    while (inhibit_manager.inhibitors.pop()) |inhibitor| {
        inhibitor.data.destroy.link.remove();
        util.gpa.destroy(inhibitor);
    }
    inhibit_manager.new_idle_inhibitor.link.remove();
}

pub fn checkActive(inhibit_manager: *IdleInhibitManager) void {
    var inhibited = false;
    var it = inhibit_manager.inhibitors.first;
    while (it) |node| : (it = node.next) {
        const node_data = SceneNodeData.fromSurface(node.data.wlr_inhibitor.surface) orelse continue;
        switch (node_data.data) {
            .view => |view| {
                if (view.current.output != null and
                    view.current.tags & view.current.output.?.current.tags != 0)
                {
                    inhibited = true;
                    break;
                }
            },
            .layer_surface => |layer_surface| {
                if (layer_surface.wlr_layer_surface.surface.mapped) {
                    inhibited = true;
                    break;
                }
            },
            .lock_surface, .override_redirect => {
                inhibited = true;
                break;
            },
        }
    }

    server.input_manager.idle_notifier.setInhibited(inhibited);
}

fn handleNewIdleInhibitor(listener: *wl.Listener(*wlr.IdleInhibitorV1), inhibitor: *wlr.IdleInhibitorV1) void {
    const inhibit_manager = @fieldParentPtr(IdleInhibitManager, "new_idle_inhibitor", listener);
    const inhibitor_node = util.gpa.create(std.TailQueue(IdleInhibitor).Node) catch return;
    inhibitor_node.data.init(inhibitor, inhibit_manager) catch {
        util.gpa.destroy(inhibitor_node);
        return;
    };

    inhibit_manager.inhibitors.append(inhibitor_node);

    inhibit_manager.checkActive();
}
