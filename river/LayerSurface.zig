// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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

const c = @import("c.zig");
const log = @import("log.zig");
const util = @import("util.zig");

const Box = @import("Box.zig");
const Output = @import("Output.zig");
const XdgPopup = @import("XdgPopup.zig");

output: *Output,
wlr_layer_surface: *c.wlr_layer_surface_v1,

box: Box = undefined,
state: c.wlr_layer_surface_v1_state,

// Listeners active the entire lifetime of the layser surface
listen_destroy: c.wl_listener = undefined,
listen_map: c.wl_listener = undefined,
listen_unmap: c.wl_listener = undefined,

// Listeners only active while the layer surface is mapped
listen_commit: c.wl_listener = undefined,
listen_new_popup: c.wl_listener = undefined,

pub fn init(self: *Self, output: *Output, wlr_layer_surface: *c.wlr_layer_surface_v1) void {
    self.* = .{
        .output = output,
        .wlr_layer_surface = wlr_layer_surface,
        .state = wlr_layer_surface.current,
    };
    wlr_layer_surface.data = self;

    // Temporarily add to the output's list to allow for inital arrangement
    // which sends the first configure.
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    const list = &output.layers[@intCast(usize, @enumToInt(self.state.layer))];
    list.append(node);
    output.arrangeLayers();
    list.remove(node);

    // Set up listeners that are active for the entire lifetime of the layer surface
    self.listen_destroy.notify = handleDestroy;
    c.wl_signal_add(&self.wlr_layer_surface.events.destroy, &self.listen_destroy);

    self.listen_map.notify = handleMap;
    c.wl_signal_add(&self.wlr_layer_surface.events.map, &self.listen_map);

    self.listen_unmap.notify = handleUnmap;
    c.wl_signal_add(&self.wlr_layer_surface.events.unmap, &self.listen_unmap);
}

fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_destroy", listener.?);
    const output = self.output;

    log.debug(.layer_shell, "layer surface '{}' destroyed", .{self.wlr_layer_surface.namespace});

    // Remove listeners active the entire lifetime of the layer surface
    c.wl_list_remove(&self.listen_destroy.link);
    c.wl_list_remove(&self.listen_map.link);
    c.wl_list_remove(&self.listen_unmap.link);

    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    util.gpa.destroy(node);
}

fn handleMap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_map", listener.?);
    const wlr_layer_surface = self.wlr_layer_surface;

    log.debug(.layer_shell, "layer surface '{}' mapped", .{wlr_layer_surface.namespace});

    // Add listeners that are only active while mapped
    self.listen_commit.notify = handleCommit;
    c.wl_signal_add(&wlr_layer_surface.surface.*.events.commit, &self.listen_commit);

    self.listen_new_popup.notify = handleNewPopup;
    c.wl_signal_add(&wlr_layer_surface.events.new_popup, &self.listen_new_popup);

    c.wlr_surface_send_enter(
        wlr_layer_surface.surface,
        wlr_layer_surface.output,
    );

    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    self.output.layers[@intCast(usize, @enumToInt(self.state.layer))].append(node);
}

fn handleUnmap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_unmap", listener.?);

    log.debug(.layer_shell, "layer surface '{}' unmapped", .{self.wlr_layer_surface.namespace});

    // remove listeners only active while the layer surface is mapped
    c.wl_list_remove(&self.listen_commit.link);
    c.wl_list_remove(&self.listen_new_popup.link);

    // Remove from the output's list of layer surfaces
    const self_node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    self.output.layers[@intCast(usize, @enumToInt(self.state.layer))].remove(self_node);

    // If the unmapped surface is focused, clear focus
    var it = self.output.root.server.input_manager.seats.first;
    while (it) |node| : (it = node.next) {
        const seat = &node.data;
        if (seat.focused == .layer and seat.focused.layer == self)
            seat.setFocusRaw(.{ .none = {} });
    }

    // This gives exclusive focus to a keyboard interactive top or overlay layer
    // surface if there is one.
    self.output.arrangeLayers();

    // Ensure that focus is given to the appropriate view if there is no
    // other top/overlay layer surface to grab focus.
    it = self.output.root.server.input_manager.seats.first;
    while (it) |node| : (it = node.next) {
        const seat = &node.data;
        seat.focus(null);
    }

    self.output.root.startTransaction();
}

fn handleCommit(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_commit", listener.?);

    if (self.wlr_layer_surface.output == null) {
        log.err(.layer_shell, "layer surface committed with null output", .{});
        return;
    }

    const new_state = &self.wlr_layer_surface.current;
    if (!std.meta.eql(self.state, new_state.*)) {
        // If the layer changed, move the LayerSurface to the proper list
        if (self.state.layer != new_state.layer) {
            const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
            self.output.layers[@intCast(usize, @enumToInt(self.state.layer))].remove(node);
            self.output.layers[@intCast(usize, @enumToInt(new_state.layer))].append(node);
        }

        self.state = new_state.*;

        self.output.arrangeLayers();
        self.output.root.startTransaction();
    }
}

fn handleNewPopup(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_new_popup", listener.?);
    const wlr_xdg_popup = util.voidCast(c.wlr_xdg_popup, data.?);

    // This will free itself on destroy
    var xdg_popup = util.gpa.create(XdgPopup) catch {
        c.wl_resource_post_no_memory(wlr_xdg_popup.resource);
        return;
    };
    xdg_popup.init(self.output, &self.box, wlr_xdg_popup);
}
