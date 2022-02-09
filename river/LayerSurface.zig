// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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

const Self = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const zwlr = @import("wayland").server.zwlr;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Box = @import("Box.zig");
const Output = @import("Output.zig");
const Subsurface = @import("Subsurface.zig");
const XdgPopup = @import("XdgPopup.zig");

const log = std.log.scoped(.layer_shell);

output: *Output,
wlr_layer_surface: *wlr.LayerSurfaceV1,

box: Box = undefined,
layer: zwlr.LayerShellV1.Layer,

destroy: wl.Listener(*wlr.LayerSurfaceV1) = wl.Listener(*wlr.LayerSurfaceV1).init(handleDestroy),
map: wl.Listener(*wlr.LayerSurfaceV1) = wl.Listener(*wlr.LayerSurfaceV1).init(handleMap),
unmap: wl.Listener(*wlr.LayerSurfaceV1) = wl.Listener(*wlr.LayerSurfaceV1).init(handleUnmap),
new_popup: wl.Listener(*wlr.XdgPopup) = wl.Listener(*wlr.XdgPopup).init(handleNewPopup),
new_subsurface: wl.Listener(*wlr.Subsurface) = wl.Listener(*wlr.Subsurface).init(handleNewSubsurface),
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),

pub fn init(self: *Self, output: *Output, wlr_layer_surface: *wlr.LayerSurfaceV1) void {
    self.* = .{
        .output = output,
        .wlr_layer_surface = wlr_layer_surface,
        .layer = wlr_layer_surface.current.layer,
    };
    wlr_layer_surface.data = @ptrToInt(self);

    // Set up listeners that are active for the entire lifetime of the layer surface
    wlr_layer_surface.events.destroy.add(&self.destroy);
    wlr_layer_surface.events.map.add(&self.map);
    wlr_layer_surface.events.unmap.add(&self.unmap);
    wlr_layer_surface.events.new_popup.add(&self.new_popup);
    wlr_layer_surface.surface.events.commit.add(&self.commit);
    wlr_layer_surface.surface.events.new_subsurface.add(&self.new_subsurface);

    // wlroots only informs us of the new surface after the first commit,
    // so our listener does not get called for this first commit. However,
    // we do want our listener called in order to send the initial configure.
    handleCommit(&self.commit, wlr_layer_surface.surface);

    Subsurface.handleExisting(wlr_layer_surface.surface, .{ .layer_surface = self });
}

fn handleDestroy(listener: *wl.Listener(*wlr.LayerSurfaceV1), wlr_layer_surface: *wlr.LayerSurfaceV1) void {
    const self = @fieldParentPtr(Self, "destroy", listener);

    log.debug("layer surface '{s}' destroyed", .{self.wlr_layer_surface.namespace});

    // Remove listeners active the entire lifetime of the layer surface
    self.destroy.link.remove();
    self.map.link.remove();
    self.unmap.link.remove();
    self.new_popup.link.remove();
    self.commit.link.remove();
    self.new_subsurface.link.remove();

    Subsurface.destroySubsurfaces(self.wlr_layer_surface.surface);
    var it = wlr_layer_surface.popups.iterator(.forward);
    while (it.next()) |wlr_xdg_popup| {
        if (@intToPtr(?*XdgPopup, wlr_xdg_popup.base.data)) |xdg_popup| xdg_popup.destroy();
    }

    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    util.gpa.destroy(node);
}

fn handleMap(listener: *wl.Listener(*wlr.LayerSurfaceV1), wlr_layer_surface: *wlr.LayerSurfaceV1) void {
    const self = @fieldParentPtr(Self, "map", listener);

    log.debug("layer surface '{s}' mapped", .{wlr_layer_surface.namespace});

    wlr_layer_surface.surface.sendEnter(wlr_layer_surface.output.?);

    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    self.output.getLayer(self.layer).append(node);
    self.output.arrangeLayers(.mapped);
}

fn handleUnmap(listener: *wl.Listener(*wlr.LayerSurfaceV1), _: *wlr.LayerSurfaceV1) void {
    const self = @fieldParentPtr(Self, "unmap", listener);

    log.debug("layer surface '{s}' unmapped", .{self.wlr_layer_surface.namespace});

    // Remove from the output's list of layer surfaces
    const self_node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    self.output.layers[@intCast(usize, @enumToInt(self.layer))].remove(self_node);

    // If the unmapped surface is focused, clear focus
    var it = server.input_manager.seats.first;
    while (it) |node| : (it = node.next) {
        const seat = &node.data;
        if (seat.focused == .layer and seat.focused.layer == self)
            seat.setFocusRaw(.{ .none = {} });
    }

    // This gives exclusive focus to a keyboard interactive top or overlay layer
    // surface if there is one.
    self.output.arrangeLayers(.mapped);

    // Ensure that focus is given to the appropriate view if there is no
    // other top/overlay layer surface to grab focus.
    it = server.input_manager.seats.first;
    while (it) |node| : (it = node.next) {
        const seat = &node.data;
        seat.focus(null);
    }

    server.root.startTransaction();
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const self = @fieldParentPtr(Self, "commit", listener);

    assert(self.wlr_layer_surface.output != null);

    // If a surface is committed while it is not mapped, we may need to send a configure.
    if (!self.wlr_layer_surface.mapped) {
        const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
        self.layer = self.wlr_layer_surface.current.layer;
        self.output.getLayer(self.layer).append(node);
        self.output.arrangeLayers(.unmapped);
        self.output.getLayer(self.layer).remove(node);
        return;
    }

    if (self.wlr_layer_surface.current.committed != 0) {
        // If the layer changed, move the LayerSurface to the proper list
        if (self.wlr_layer_surface.current.layer != self.layer) {
            const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
            self.output.getLayer(self.layer).remove(node);
            self.layer = self.wlr_layer_surface.current.layer;
            self.output.getLayer(self.layer).append(node);
        }

        self.output.arrangeLayers(.mapped);
        server.root.startTransaction();
    }

    self.output.damage.?.addWhole();
}

fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const self = @fieldParentPtr(Self, "new_popup", listener);
    XdgPopup.create(wlr_xdg_popup, .{ .layer_surface = self });
}

fn handleNewSubsurface(listener: *wl.Listener(*wlr.Subsurface), new_wlr_subsurface: *wlr.Subsurface) void {
    const self = @fieldParentPtr(Self, "new_subsurface", listener);
    Subsurface.create(new_wlr_subsurface, .{ .layer_surface = self });
}
