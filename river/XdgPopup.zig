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

const log = @import("log.zig");
const util = @import("util.zig");

const Box = @import("Box.zig");
const Output = @import("Output.zig");

/// The output this popup is displayed on.
output: *Output,

/// Box of the parent of this popup tree. Needed to unconstrain child popups.
parent_box: *const Box,

/// The corresponding wlroots object
wlr_xdg_popup: *wlr.XdgPopup,

destroy: wl.Listener(*wlr.XdgSurface) = undefined,
new_popup: wl.Listener(*wlr.XdgPopup) = undefined,

pub fn init(self: *Self, output: *Output, parent_box: *const Box, wlr_xdg_popup: *wlr.XdgPopup) void {
    self.* = .{
        .output = output,
        .parent_box = parent_box,
        .wlr_xdg_popup = wlr_xdg_popup,
    };

    // The output box relative to the parent of the popup
    var box = output.root.output_layout.getBox(output.wlr_output).?.*;
    box.x -= parent_box.x;
    box.y -= parent_box.y;
    wlr_xdg_popup.unconstrainFromBox(&box);

    self.destroy.setNotify(handleDestroy);
    wlr_xdg_popup.base.events.destroy.add(&self.destroy);

    self.new_popup.setNotify(handleNewPopup);
    wlr_xdg_popup.base.events.new_popup.add(&self.new_popup);
}

fn handleDestroy(listener: *wl.Listener(*wlr.XdgSurface), wlr_xdg_surface: *wlr.XdgSurface) void {
    const self = @fieldParentPtr(Self, "destroy", listener);

    self.destroy.link.remove();
    self.new_popup.link.remove();

    util.gpa.destroy(self);
}

/// Called when a new xdg popup is requested by the client
fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const self = @fieldParentPtr(Self, "new_popup", listener);

    // This will free itself on destroy
    const xdg_popup = util.gpa.create(Self) catch {
        wlr_xdg_popup.resource.postNoMemory();
        log.crit(.server, "out of memory", .{});
        return;
    };
    xdg_popup.init(self.output, self.parent_box, wlr_xdg_popup);
}
