// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
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
const util = @import("util.zig");

const Box = @import("Box.zig");
const Output = @import("Output.zig");

/// The output this popup is displayed on.
output: *Output,

/// Box of the parent of this popup tree. Needed to unconstrain child popups.
parent_box: *const Box,

/// The corresponding wlroots object
wlr_xdg_popup: *c.wlr_xdg_popup,

listen_destroy: c.wl_listener,
listen_new_popup: c.wl_listener,

pub fn init(
    self: *Self,
    output: *Output,
    parent_box: *const Box,
    wlr_xdg_popup: *c.wlr_xdg_popup,
) void {
    self.output = output;
    self.parent_box = parent_box;
    self.wlr_xdg_popup = wlr_xdg_popup;

    // The output box relative to the parent of the popup
    var box = c.wlr_output_layout_get_box(output.root.wlr_output_layout, output.wlr_output).*;
    box.x -= parent_box.x;
    box.y -= parent_box.y;
    c.wlr_xdg_popup_unconstrain_from_box(wlr_xdg_popup, &box);

    // Setup listeners
    self.listen_destroy.notify = handleDestroy;
    c.wl_signal_add(&wlr_xdg_popup.base.*.events.destroy, &self.listen_destroy);

    self.listen_new_popup.notify = handleNewPopup;
    c.wl_signal_add(&wlr_xdg_popup.base.*.events.new_popup, &self.listen_new_popup);
}

fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_destroy", listener.?);

    c.wl_list_remove(&self.listen_destroy.link);
    c.wl_list_remove(&self.listen_new_popup.link);

    util.allocator.destroy(self);
}

/// Called when a new xdg popup is requested by the client
fn handleNewPopup(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_new_popup", listener.?);
    const wlr_xdg_popup = util.voidCast(c.wlr_xdg_popup, data.?);

    // This will free itself on destroy
    var xdg_popup = util.allocator.create(Self) catch unreachable;
    xdg_popup.init(self.output, self.parent_box, wlr_xdg_popup);
}
