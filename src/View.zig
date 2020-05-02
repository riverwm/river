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

const Box = @import("Box.zig");
const Log = @import("log.zig").Log;
const Output = @import("Output.zig");
const Root = @import("Root.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XdgToplevel = @import("XdgToplevel.zig");

const ViewImpl = union(enum) {
    xdg_toplevel: XdgToplevel,
};

/// The implementation of this view
impl: ViewImpl,

/// The output this view is currently associated with
output: *Output,

/// This is non-null exactly when the view is mapped
wlr_surface: ?*c.wlr_surface,

/// If the view is floating or not
floating: bool,

/// True if the view is currentlt focused by at lease one seat
focused: bool,

/// The current output-relative coordinates and dimensions of the view
current_box: Box,
pending_box: ?Box,

/// The dimensions the view would have taken if we didn't force it to tile
natural_width: u32,
natural_height: u32,

current_tags: u32,
pending_tags: ?u32,

pending_serial: ?u32,

// This is what we render while a transaction is in progress
stashed_buffer: ?*c.wlr_buffer,

pub fn init_xdg_toplevel(
    self: *Self,
    output: *Output,
    tags: u32,
    wlr_xdg_surface: *c.wlr_xdg_surface,
) void {
    self.output = output;

    self.wlr_surface = null;

    self.focused = false;

    self.current_box = Box{
        .x = 0,
        .y = 0,
        .height = 0,
        .width = 0,
    };
    self.pending_box = null;

    self.current_tags = tags;
    self.pending_tags = null;

    self.pending_serial = null;

    self.stashed_buffer = null;

    self.impl = .{ .xdg_toplevel = undefined };
    self.impl.xdg_toplevel.init(self, wlr_xdg_surface);
}

pub fn deinit(self: *Self) void {
    if (self.stashed_buffer) |buffer| {
        c.wlr_buffer_unref(buffer);
    }
}

pub fn needsConfigure(self: Self) bool {
    if (self.pending_box) |pending_box| {
        return pending_box.width != self.current_box.width or
            pending_box.height != self.current_box.height;
    } else {
        return false;
    }
}

pub fn configure(self: Self) void {
    if (self.pending_box) |pending_box| {
        switch (self.impl) {
            .xdg_toplevel => |xdg_toplevel| xdg_toplevel.configure(pending_box),
        }
    } else {
        Log.Error.log("Configure called on a View with no pending box", .{});
    }
}

pub fn sendFrameDone(self: Self) void {
    var now: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &now);
    c.wlr_surface_send_frame_done(self.wlr_surface.?, &now);
}

pub fn dropStashedBuffer(self: *Self) void {
    // TODO: log debug error
    if (self.stashed_buffer) |buffer| {
        c.wlr_buffer_unref(buffer);
        self.stashed_buffer = null;
    }
}

pub fn stashBuffer(self: *Self) void {
    // TODO: log debug error if there is already a saved buffer
    if (self.wlr_surface) |wlr_surface| {
        if (c.wlr_surface_has_buffer(wlr_surface)) {
            _ = c.wlr_buffer_ref(wlr_surface.buffer);
            self.stashed_buffer = wlr_surface.buffer;
        }
    }
}

/// Set the focued bool and the active state of the view if it is a toplevel
pub fn setFocused(self: *Self, focused: bool) void {
    self.focused = focused;
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.setActivated(focused),
    }
}

/// If true is passsed, make the view float. If false, return it to the tiled
/// layout.
pub fn setFloating(self: *Self, float: bool) void {
    if (float and !self.floating) {
        self.floating = true;
        self.pending_box = Box{
            .x = std.math.max(0, @divTrunc(@intCast(i32, self.output.usable_box.width) -
                @intCast(i32, self.natural_width), 2)),
            .y = std.math.max(0, @divTrunc(@intCast(i32, self.output.usable_box.height) -
                @intCast(i32, self.natural_height), 2)),
            .width = self.natural_width,
            .height = self.natural_height,
        };
    } else if (!float and self.floating) {
        self.floating = false;
    }
}

/// Move a view from one output to another, sending the required enter/leave
/// events.
pub fn sendToOutput(self: *Self, destination_output: *Output) void {
    const node = @fieldParentPtr(ViewStack(Self).Node, "view", self);

    self.output.views.remove(node);
    destination_output.views.push(node);

    c.wlr_surface_send_leave(self.wlr_surface, self.output.wlr_output);
    c.wlr_surface_send_enter(self.wlr_surface, destination_output.wlr_output);

    self.output = destination_output;
}

pub fn close(self: Self) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.close(),
    }
}

pub fn forEachSurface(
    self: Self,
    iterator: c.wlr_surface_iterator_func_t,
    user_data: ?*c_void,
) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.forEachSurface(iterator, user_data),
    }
}
