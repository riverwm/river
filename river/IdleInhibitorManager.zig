const Self = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const IdleInhibitor = @import("IdleInhibitor.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const View = @import("View.zig");

idle_inhibit_manager: *wlr.IdleInhibitManagerV1,
new_idle_inhibitor: wl.Listener(*wlr.IdleInhibitorV1),
inhibitors: std.TailQueue(IdleInhibitor) = .{},

pub fn init(self: *Self) !void {
    self.idle_inhibit_manager = try wlr.IdleInhibitManagerV1.create(server.wl_server);
    self.new_idle_inhibitor.setNotify(handleNewIdleInhibitor);
    self.idle_inhibit_manager.events.new_inhibitor.add(&self.new_idle_inhibitor);
}

pub fn deinit(self: *Self) void {
    while (self.inhibitors.pop()) |inhibitor| {
        inhibitor.data.destroy.link.remove();
        util.gpa.destroy(inhibitor);
    }
    self.new_idle_inhibitor.link.remove();
}

pub fn idleInhibitCheckActive(self: *Self) void {
    var inhibited = false;
    var it = self.inhibitors.first;
    while (it) |node| : (it = node.next) {
        const node_data = SceneNodeData.fromSurface(node.data.inhibitor.surface) orelse continue;
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
            .lock_surface, .xwayland_override_redirect => {
                inhibited = true;
                break;
            },
        }
    }

    server.input_manager.idle_notifier.setInhibited(inhibited);
}

fn handleNewIdleInhibitor(listener: *wl.Listener(*wlr.IdleInhibitorV1), inhibitor: *wlr.IdleInhibitorV1) void {
    const self = @fieldParentPtr(Self, "new_idle_inhibitor", listener);
    const inhibitor_node = util.gpa.create(std.TailQueue(IdleInhibitor).Node) catch return;
    inhibitor_node.data.init(inhibitor, self) catch {
        util.gpa.destroy(inhibitor_node);
        return;
    };

    self.inhibitors.append(inhibitor_node);

    self.idleInhibitCheckActive();
}
