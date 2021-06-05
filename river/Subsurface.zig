// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 The River Developers
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

const Subsurface = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const util = @import("util.zig");

const LayerSurface = @import("LayerSurface.zig");
const View = @import("View.zig");

pub const Parent = union(enum) {
    view: *View,
    layer_surface: *LayerSurface,

    pub fn damageWholeOutput(parent: Parent) void {
        switch (parent) {
            .view => |view| view.output.damage.addWhole(),
            .layer_surface => |layer_surface| layer_surface.output.damage.addWhole(),
        }
    }
};

/// The parent at the root of this surface tree
parent: Parent,
wlr_subsurface: *wlr.Subsurface,

// Always active
destroy: wl.Listener(*wlr.Subsurface) = wl.Listener(*wlr.Subsurface).init(handleDestroy),
map: wl.Listener(*wlr.Subsurface) = wl.Listener(*wlr.Subsurface).init(handleMap),
unmap: wl.Listener(*wlr.Subsurface) = wl.Listener(*wlr.Subsurface).init(handleUnmap),
new_subsurface: wl.Listener(*wlr.Subsurface) = wl.Listener(*wlr.Subsurface).init(handleNewSubsurface),

// Only active while mapped
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),

pub fn create(wlr_subsurface: *wlr.Subsurface, parent: Parent) void {
    const subsurface = util.gpa.create(Subsurface) catch {
        std.log.crit("out of memory", .{});
        wlr_subsurface.resource.getClient().postNoMemory();
        return;
    };
    subsurface.* = .{ .wlr_subsurface = wlr_subsurface, .parent = parent };

    wlr_subsurface.events.destroy.add(&subsurface.destroy);
    wlr_subsurface.events.map.add(&subsurface.map);
    wlr_subsurface.events.unmap.add(&subsurface.unmap);
    wlr_subsurface.surface.events.new_subsurface.add(&subsurface.new_subsurface);

    // There may already be subsurfaces present on this surface that we
    // aren't aware of and won't receive a new_subsurface event for.
    var it = wlr_subsurface.surface.subsurfaces.iterator(.forward);
    while (it.next()) |s| Subsurface.create(s, parent);
}

fn handleDestroy(listener: *wl.Listener(*wlr.Subsurface), wlr_subsurface: *wlr.Subsurface) void {
    const subsurface = @fieldParentPtr(Subsurface, "destroy", listener);

    subsurface.destroy.link.remove();
    subsurface.map.link.remove();
    subsurface.unmap.link.remove();
    subsurface.new_subsurface.link.remove();

    util.gpa.destroy(subsurface);
}

fn handleMap(listener: *wl.Listener(*wlr.Subsurface), wlr_subsurface: *wlr.Subsurface) void {
    const subsurface = @fieldParentPtr(Subsurface, "map", listener);

    wlr_subsurface.surface.events.commit.add(&subsurface.commit);
    subsurface.parent.damageWholeOutput();
}

fn handleUnmap(listener: *wl.Listener(*wlr.Subsurface), wlr_subsurface: *wlr.Subsurface) void {
    const subsurface = @fieldParentPtr(Subsurface, "unmap", listener);

    subsurface.commit.link.remove();
    subsurface.parent.damageWholeOutput();
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), surface: *wlr.Surface) void {
    const subsurface = @fieldParentPtr(Subsurface, "commit", listener);

    subsurface.parent.damageWholeOutput();
}

fn handleNewSubsurface(listener: *wl.Listener(*wlr.Subsurface), new_wlr_subsurface: *wlr.Subsurface) void {
    const subsurface = @fieldParentPtr(Subsurface, "new_subsurface", listener);

    Subsurface.create(new_wlr_subsurface, subsurface.parent);
}
