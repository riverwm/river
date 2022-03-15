const Self = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const IdleInhibitor = @import("IdleInhibitor.zig");

idle_inhibit_manager: *wlr.IdleInhibitManagerV1,
new_idle_inhibitor: wl.Listener(*wlr.IdleInhibitorV1),
inhibitors: std.TailQueue(IdleInhibitor) = .{},
idle: *wlr.Idle,

pub fn init(self: *Self, idle: *wlr.Idle) !void {
    self.idle_inhibit_manager = try wlr.IdleInhibitManagerV1.create(server.wl_server);
    self.idle = idle;
    self.new_idle_inhibitor.setNotify(handleNewIdleInhibitor);
    self.idle_inhibit_manager.events.new_inhibitor.add(&self.new_idle_inhibitor);
}

pub fn deinit(self: *Self) void {
    while (self.inhibitors.pop()) |inhibitor| {
        util.gpa.destroy(inhibitor);
    }
}

pub fn idleInhibitCheckActive(self: *Self) void {
    var inhibited = false;
    var it = self.inhibitors.first;
    while (it) |node| : (it = node.next) {
        // If for whatever reason the inhibitor does not have a view, then
        // assume it is visible.
        if (node.data.view == null) {
            inhibited = true;
            break;
        }
        // If view is visible,
        if (node.data.view.?.current.tags & node.data.view.?.output.current.tags != 0) {
            inhibited = true;
            break;
        }
    }

    self.idle.setEnabled(null, !inhibited);
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
