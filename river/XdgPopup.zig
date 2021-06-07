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
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const util = @import("util.zig");

const Subsurface = @import("Subsurface.zig");
const Parent = Subsurface.Parent;

/// The parent at the root of this surface tree
parent: Parent,
wlr_xdg_popup: *wlr.XdgPopup,

// Always active
destroy: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(handleDestroy),
map: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(handleMap),
unmap: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(handleUnmap),
new_popup: wl.Listener(*wlr.XdgPopup) = wl.Listener(*wlr.XdgPopup).init(handleNewPopup),
new_subsurface: wl.Listener(*wlr.Subsurface) = wl.Listener(*wlr.Subsurface).init(handleNewSubsurface),

// Only active while mapped
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),

pub fn create(wlr_xdg_popup: *wlr.XdgPopup, parent: Parent) void {
    const self = util.gpa.create(Self) catch {
        std.log.crit("out of memory", .{});
        wlr_xdg_popup.resource.postNoMemory();
        return;
    };
    self.* = .{
        .parent = parent,
        .wlr_xdg_popup = wlr_xdg_popup,
    };

    const parent_box = switch (parent) {
        .view => |view| &view.pending.box,
        .layer_surface => |layer_surface| &layer_surface.box,
        .drag_icon => unreachable,
    };
    const output_dimensions = switch (parent) {
        .view => |view| view.output.getEffectiveResolution(),
        .layer_surface => |layer_surface| layer_surface.output.getEffectiveResolution(),
        .drag_icon => unreachable,
    };

    // The output box relative to the parent of the popup
    var box = wlr.Box{
        .x = -parent_box.x,
        .y = -parent_box.y,
        .width = @intCast(c_int, output_dimensions.width),
        .height = @intCast(c_int, output_dimensions.height),
    };
    wlr_xdg_popup.unconstrainFromBox(&box);

    wlr_xdg_popup.base.events.destroy.add(&self.destroy);
    wlr_xdg_popup.base.events.map.add(&self.map);
    wlr_xdg_popup.base.events.unmap.add(&self.unmap);
    wlr_xdg_popup.base.events.new_popup.add(&self.new_popup);
    wlr_xdg_popup.base.surface.events.new_subsurface.add(&self.new_subsurface);

    // There may already be subsurfaces present on this surface that we
    // aren't aware of and won't receive a new_subsurface event for.
    var it = wlr_xdg_popup.base.surface.subsurfaces.iterator(.forward);
    while (it.next()) |s| Subsurface.create(s, parent);
}

fn handleDestroy(listener: *wl.Listener(*wlr.XdgSurface), wlr_xdg_surface: *wlr.XdgSurface) void {
    const self = @fieldParentPtr(Self, "destroy", listener);

    self.destroy.link.remove();
    self.map.link.remove();
    self.unmap.link.remove();
    self.new_popup.link.remove();
    self.new_subsurface.link.remove();

    util.gpa.destroy(self);
}

fn handleMap(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
    const self = @fieldParentPtr(Self, "map", listener);

    self.wlr_xdg_popup.base.surface.events.commit.add(&self.commit);
    self.parent.damageWholeOutput();
}

fn handleUnmap(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
    const self = @fieldParentPtr(Self, "unmap", listener);

    self.commit.link.remove();
    self.parent.damageWholeOutput();
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), surface: *wlr.Surface) void {
    const self = @fieldParentPtr(Self, "commit", listener);

    self.parent.damageWholeOutput();
}

fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const self = @fieldParentPtr(Self, "new_popup", listener);

    Self.create(wlr_xdg_popup, self.parent);
}

fn handleNewSubsurface(listener: *wl.Listener(*wlr.Subsurface), new_wlr_subsurface: *wlr.Subsurface) void {
    const self = @fieldParentPtr(Self, "new_subsurface", listener);

    Subsurface.create(new_wlr_subsurface, self.parent);
}
