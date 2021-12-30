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

const XdgPopup = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const util = @import("util.zig");

const Subsurface = @import("Subsurface.zig");
const Parent = Subsurface.Parent;

/// The parent at the root of this surface tree
parent: Parent,
wlr_xdg_popup: *wlr.XdgPopup,

// Always active
surface_destroy: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(handleDestroy),
map: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(handleMap),
unmap: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(handleUnmap),
new_popup: wl.Listener(*wlr.XdgPopup) = wl.Listener(*wlr.XdgPopup).init(handleNewPopup),
new_subsurface: wl.Listener(*wlr.Subsurface) = wl.Listener(*wlr.Subsurface).init(handleNewSubsurface),

// Only active while mapped
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),

pub fn create(wlr_xdg_popup: *wlr.XdgPopup, parent: Parent) void {
    const xdg_popup = util.gpa.create(XdgPopup) catch {
        std.log.err("out of memory", .{});
        wlr_xdg_popup.resource.postNoMemory();
        return;
    };
    xdg_popup.* = .{
        .parent = parent,
        .wlr_xdg_popup = wlr_xdg_popup,
    };
    assert(wlr_xdg_popup.base.data == 0);
    wlr_xdg_popup.base.data = @ptrToInt(xdg_popup);

    switch (parent) {
        .xdg_toplevel => |xdg_toplevel| {
            const output_dimensions = xdg_toplevel.view.output.getEffectiveResolution();
            // The output box relative to the parent of the xdg_popup
            var box = wlr.Box{
                .x = xdg_toplevel.view.surface_box.x - xdg_toplevel.view.pending.box.x,
                .y = xdg_toplevel.view.surface_box.y - xdg_toplevel.view.pending.box.y,
                .width = @intCast(c_int, output_dimensions.width),
                .height = @intCast(c_int, output_dimensions.height),
            };
            wlr_xdg_popup.unconstrainFromBox(&box);
        },
        .layer_surface => |layer_surface| {
            const output_dimensions = layer_surface.output.getEffectiveResolution();
            // The output box relative to the parent of the xdg_popup
            var box = wlr.Box{
                .x = layer_surface.box.x,
                .y = layer_surface.box.y,
                .width = @intCast(c_int, output_dimensions.width),
                .height = @intCast(c_int, output_dimensions.height),
            };
            wlr_xdg_popup.unconstrainFromBox(&box);
        },
        .drag_icon, .lock_surface => unreachable,
    }

    wlr_xdg_popup.base.events.destroy.add(&xdg_popup.surface_destroy);
    wlr_xdg_popup.base.events.map.add(&xdg_popup.map);
    wlr_xdg_popup.base.events.unmap.add(&xdg_popup.unmap);
    wlr_xdg_popup.base.events.new_popup.add(&xdg_popup.new_popup);
    wlr_xdg_popup.base.surface.events.new_subsurface.add(&xdg_popup.new_subsurface);

    Subsurface.handleExisting(wlr_xdg_popup.base.surface, parent);
}

pub fn destroy(xdg_popup: *XdgPopup) void {
    xdg_popup.surface_destroy.link.remove();
    xdg_popup.map.link.remove();
    xdg_popup.unmap.link.remove();
    xdg_popup.new_popup.link.remove();
    xdg_popup.new_subsurface.link.remove();

    if (xdg_popup.wlr_xdg_popup.base.mapped) xdg_popup.commit.link.remove();

    Subsurface.destroySubsurfaces(xdg_popup.wlr_xdg_popup.base.surface);
    XdgPopup.destroyPopups(xdg_popup.wlr_xdg_popup.base);

    xdg_popup.wlr_xdg_popup.base.data = 0;
    util.gpa.destroy(xdg_popup);
}

pub fn destroyPopups(wlr_xdg_surface: *wlr.XdgSurface) void {
    var it = wlr_xdg_surface.popups.iterator(.forward);
    while (it.next()) |wlr_xdg_popup| {
        if (@intToPtr(?*XdgPopup, wlr_xdg_popup.base.data)) |xdg_popup| xdg_popup.destroy();
    }
}

fn handleDestroy(listener: *wl.Listener(*wlr.XdgSurface), _: *wlr.XdgSurface) void {
    const xdg_popup = @fieldParentPtr(XdgPopup, "surface_destroy", listener);
    xdg_popup.destroy();
}

fn handleMap(listener: *wl.Listener(*wlr.XdgSurface), _: *wlr.XdgSurface) void {
    const xdg_popup = @fieldParentPtr(XdgPopup, "map", listener);

    xdg_popup.wlr_xdg_popup.base.surface.events.commit.add(&xdg_popup.commit);
    xdg_popup.parent.damageWholeOutput();
}

fn handleUnmap(listener: *wl.Listener(*wlr.XdgSurface), _: *wlr.XdgSurface) void {
    const xdg_popup = @fieldParentPtr(XdgPopup, "unmap", listener);

    xdg_popup.commit.link.remove();
    xdg_popup.parent.damageWholeOutput();
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const xdg_popup = @fieldParentPtr(XdgPopup, "commit", listener);

    xdg_popup.parent.damageWholeOutput();
}

fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const xdg_popup = @fieldParentPtr(XdgPopup, "new_popup", listener);

    XdgPopup.create(wlr_xdg_popup, xdg_popup.parent);
}

fn handleNewSubsurface(listener: *wl.Listener(*wlr.Subsurface), new_wlr_subsurface: *wlr.Subsurface) void {
    const xdg_popup = @fieldParentPtr(XdgPopup, "new_subsurface", listener);

    Subsurface.create(new_wlr_subsurface, xdg_popup.parent);
}
