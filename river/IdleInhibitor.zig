const Self = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const View = @import("View.zig");
const IdleInhibitorManager = @import("IdleInhibitorManager.zig");

inhibitor_manager: *IdleInhibitorManager,
inhibitor: *wlr.IdleInhibitorV1,
destroy: wl.Listener(*wlr.IdleInhibitorV1) = wl.Listener(*wlr.IdleInhibitorV1).init(handleDestroy),
view: ?*View = null,

pub fn init(self: *Self, inhibitor: *wlr.IdleInhibitorV1, inhibitor_manager: *IdleInhibitorManager) !void {
    self.inhibitor_manager = inhibitor_manager;
    self.inhibitor = inhibitor;
    self.view = View.fromWlrSurface(inhibitor.surface);
    self.destroy.setNotify(handleDestroy);
    inhibitor.events.destroy.add(&self.destroy);

    inhibitor_manager.idleInhibitCheckActive();
}

fn handleDestroy(listener: *wl.Listener(*wlr.IdleInhibitorV1), _: *wlr.IdleInhibitorV1) void {
    const self = @fieldParentPtr(Self, "destroy", listener);
    self.destroy.link.remove();

    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    server.idle_inhibitor_manager.inhibitors.remove(node);
    util.gpa.destroy(node);

    self.inhibitor_manager.idleInhibitCheckActive();
}
