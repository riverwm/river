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

const build_options = @import("build_options");
const std = @import("std");

const c = @import("c.zig");
const log = @import("log.zig");
const util = @import("util.zig");

const Box = @import("Box.zig");
const Output = @import("Output.zig");
const Root = @import("Root.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandView = if (build_options.xwayland) @import("XwaylandView.zig") else @import("VoidView.zig");

pub const Constraints = struct {
    min_width: u32,
    max_width: u32,
    min_height: u32,
    max_height: u32,
};

// Minimum width/height for surfaces.
// This is needed, because external layouts and large padding and border sizes
// may cause surfaces so small, that bugs in client applications are encountered,
// or even surfaces of zero or negative size,which are a protocol error and would
// likely cause river to crash. The value is totally arbitrary and low enough,
// that it should never be encountered during normal usage.
pub const min_size = 50;

const Impl = union(enum) {
    xdg_toplevel: XdgToplevel,
    xwayland_view: XwaylandView,
};

const State = struct {
    /// The output-relative coordinates and dimensions of the view. The
    /// surface itself may have other dimensions which are stored in the
    /// surface_box member.
    box: Box,

    /// The tags of the view, as a bitmask
    tags: u32,

    /// Number of seats currently focusing the view
    focus: u32,

    float: bool,
    fullscreen: bool,
};

const SavedBuffer = struct {
    wlr_client_buffer: *c.wlr_client_buffer,
    box: Box,
    transform: c.wl_output_transform,
};

/// The implementation of this view
impl: Impl,

/// The output this view is currently associated with
output: *Output,

/// This is non-null exactly when the view is mapped
wlr_surface: ?*c.wlr_surface,

/// The double-buffered state of the view
current: State,
pending: State,

/// The serial sent with the currently pending configure event
pending_serial: ?u32,

/// The currently commited geometry of the surface. The x/y may be negative if
/// for example the client has decided to draw CSD shadows a la GTK.
surface_box: Box,

/// The geometry the view's surface had when the transaction started and
/// buffers were saved.
saved_surface_box: Box,

/// These are what we render while a transaction is in progress
saved_buffers: std.ArrayList(SavedBuffer),

/// The floating dimensions the view, saved so that they can be restored if the
/// view returns to floating mode.
float_box: Box,

draw_borders: bool,

pub fn init(self: *Self, output: *Output, tags: u32, surface: var) void {
    self.output = output;

    self.wlr_surface = null;

    self.current = .{
        .box = .{
            .x = 0,
            .y = 0,
            .height = 0,
            .width = 0,
        },
        .tags = tags,
        .focus = 0,
        .float = false,
        .fullscreen = false,
    };
    self.pending = self.current;

    self.pending_serial = null;

    self.saved_buffers = std.ArrayList(SavedBuffer).init(util.gpa);

    self.draw_borders = true;

    if (@TypeOf(surface) == *c.wlr_xdg_surface) {
        self.impl = .{ .xdg_toplevel = undefined };
        self.impl.xdg_toplevel.init(self, surface);
    } else if (build_options.xwayland and @TypeOf(surface) == *c.wlr_xwayland_surface) {
        self.impl = .{ .xwayland_view = undefined };
        self.impl.xwayland_view.init(self, surface);
    } else unreachable;
}

pub fn deinit(self: Self) void {
    for (self.saved_buffers.items) |buffer| c.wlr_buffer_unlock(&buffer.wlr_client_buffer.*.base);
    self.saved_buffers.deinit();
}

/// Handle changes to pending state and start a transaction to apply them
pub fn applyPending(self: *Self) void {
    var arrange_output = false;

    if (self.current.tags != self.pending.tags)
        arrange_output = true;

    // If switching from float -> layout or layout -> float arrange the output
    // to get assigned a new size or fill the hole in the layout left behind
    if (self.current.float != self.pending.float)
        arrange_output = true;

    // If switching from float to something else save the dimensions
    if (self.current.float and !self.pending.float)
        self.float_box = self.current.box;

    // If switching from something else to float restore the dimensions
    if ((!self.current.float and self.pending.float) or
        (self.current.fullscreen and !self.pending.fullscreen and self.pending.float))
        self.pending.box = self.float_box;

    // If switching to fullscreen set the dimensions to the full area of the output
    if (!self.current.fullscreen and self.pending.fullscreen)
        self.pending.box = Box.fromWlrBox(
            c.wlr_output_layout_get_box(self.output.root.wlr_output_layout, self.output.wlr_output).*,
        );

    // If switching from fullscreen to layout, arrange the output to get
    // assigned the proper size.
    if (self.current.fullscreen and !self.pending.fullscreen and !self.pending.float)
        arrange_output = true;

    if (arrange_output) self.output.arrangeViews();

    self.output.root.startTransaction();
}

pub fn needsConfigure(self: Self) bool {
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.needsConfigure(),
        .xwayland_view => |xwayland_view| xwayland_view.needsConfigure(),
    };
}

pub fn configure(self: Self) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.configure(),
        .xwayland_view => |xwayland_view| xwayland_view.configure(),
    }
}

pub fn sendFrameDone(self: Self) void {
    var now: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &now);
    c.wlr_surface_send_frame_done(self.wlr_surface.?, &now);
}

pub fn dropSavedBuffers(self: *Self) void {
    for (self.saved_buffers.items) |buffer| c.wlr_buffer_unlock(&buffer.wlr_client_buffer.*.base);
    self.saved_buffers.items.len = 0;
}

pub fn saveBuffers(self: *Self) void {
    std.debug.assert(self.saved_buffers.items.len == 0);
    self.saved_surface_box = self.surface_box;
    self.forEachSurface(saveBuffersIterator, &self.saved_buffers);
}

fn saveBuffersIterator(
    wlr_surface: ?*c.wlr_surface,
    surface_x: c_int,
    surface_y: c_int,
    data: ?*c_void,
) callconv(.C) void {
    const saved_buffers = util.voidCast(std.ArrayList(SavedBuffer), data.?);
    if (wlr_surface) |surface| {
        if (c.wlr_surface_has_buffer(surface)) {
            saved_buffers.append(.{
                .wlr_client_buffer = surface.buffer,
                .box = Box{
                    .x = surface_x,
                    .y = surface_y,
                    .width = @intCast(u32, surface.current.width),
                    .height = @intCast(u32, surface.current.height),
                },
                .transform = surface.current.transform,
            }) catch return;
            _ = c.wlr_buffer_lock(&surface.buffer.*.base);
        }
    }
}

/// Move a view from one output to another, sending the required enter/leave
/// events.
pub fn sendToOutput(self: *Self, destination_output: *Output) void {
    const node = @fieldParentPtr(ViewStack(Self).Node, "view", self);

    self.output.views.remove(node);
    destination_output.views.push(node);

    self.output.sendViewTags();
    destination_output.sendViewTags();

    c.wlr_surface_send_leave(self.wlr_surface, self.output.wlr_output);
    c.wlr_surface_send_enter(self.wlr_surface, destination_output.wlr_output);

    self.output = destination_output;
}

pub fn close(self: Self) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.close(),
        .xwayland_view => |xwayland_view| xwayland_view.close(),
    }
}

pub fn forEachSurface(
    self: Self,
    iterator: c.wlr_surface_iterator_func_t,
    user_data: ?*c_void,
) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.forEachSurface(iterator, user_data),
        .xwayland_view => |xwayland_view| xwayland_view.forEachSurface(iterator, user_data),
    }
}

/// Return the surface at output coordinates ox, oy and set sx, sy to the
/// corresponding surface-relative coordinates, if there is a surface.
pub fn surfaceAt(self: Self, ox: f64, oy: f64, sx: *f64, sy: *f64) ?*c.wlr_surface {
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.surfaceAt(ox, oy, sx, sy),
        .xwayland_view => |xwayland_view| xwayland_view.surfaceAt(ox, oy, sx, sy),
    };
}

/// Return the current title of the view. May be an empty string.
pub fn getTitle(self: Self) [*:0]const u8 {
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.getTitle(),
        .xwayland_view => |xwayland_view| xwayland_view.getTitle(),
    };
}

/// Clamp the width/height of the pending state to the constraints of the view
pub fn applyConstraints(self: *Self) void {
    const constraints = self.getConstraints();
    const box = &self.pending.box;
    box.width = std.math.clamp(box.width, constraints.min_width, constraints.max_width);
    box.height = std.math.clamp(box.height, constraints.min_height, constraints.max_height);
}

/// Return bounds on the dimensions of the view
pub fn getConstraints(self: Self) Constraints {
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.getConstraints(),
        .xwayland_view => |xwayland_view| xwayland_view.getConstraints(),
    };
}

/// Find and return the view corresponding to a given wlr_surface, if any
pub fn fromWlrSurface(wlr_surface: *c.wlr_surface) ?*Self {
    if (c.wlr_surface_is_xdg_surface(wlr_surface)) {
        const wlr_xdg_surface = c.wlr_xdg_surface_from_wlr_surface(wlr_surface);
        if (wlr_xdg_surface.*.role == .WLR_XDG_SURFACE_ROLE_TOPLEVEL) {
            return util.voidCast(Self, wlr_xdg_surface.*.data.?);
        }
    }
    if (build_options.xwayland) {
        if (c.wlr_surface_is_xwayland_surface(wlr_surface)) {
            const wlr_xwayland_surface = c.wlr_xwayland_surface_from_wlr_surface(wlr_surface);
            return util.voidCast(Self, wlr_xwayland_surface.*.data.?);
        }
    }
    return null;
}

pub fn shouldTrackConfigure(self: Self) bool {
    // There are exactly three cases in which we do not track configures
    // 1. the view was and remains floating
    // 2. the view is changing from float/layout to fullscreen
    // 3. the view is changing from fullscreen to float
    return !((self.pending.float and self.current.float) or
        (self.pending.fullscreen and !self.current.fullscreen) or
        (self.pending.float and !self.pending.fullscreen and self.current.fullscreen));
}

/// Called by the impl when the surface is ready to be displayed
pub fn map(self: *Self) void {
    const root = self.output.root;

    log.debug(.server, "view '{}' mapped", .{self.getTitle()});

    // Add the view to the stack of its output
    const node = @fieldParentPtr(ViewStack(Self).Node, "view", self);
    self.output.views.push(node);

    // Focus the new view, assuming the seat is focusing the proper output
    // and there isn't something else like a fullscreen view grabbing focus.
    var it = root.server.input_manager.seats.first;
    while (it) |seat_node| : (it = seat_node.next) seat_node.data.focus(self);

    c.wlr_surface_send_enter(self.wlr_surface.?, self.output.wlr_output);

    self.output.sendViewTags();

    self.output.arrangeViews();
    self.output.root.startTransaction();
}

/// Called by the impl when the surface will no longer be displayed
pub fn unmap(self: *Self) void {
    const root = self.output.root;

    log.debug(.server, "view '{}' unmapped", .{self.getTitle()});

    // Inform all seats that the view has been unmapped so they can handle focus
    var it = root.server.input_manager.seats.first;
    while (it) |node| : (it = node.next) {
        const seat = &node.data;
        seat.handleViewUnmap(self);
    }

    self.wlr_surface = null;

    // Remove the view from its output's stack
    const node = @fieldParentPtr(ViewStack(Self).Node, "view", self);
    self.output.views.remove(node);

    self.output.sendViewTags();

    // Still need to arrange if fullscreened from the layout
    if (!self.current.float) {
        self.output.arrangeViews();
        root.startTransaction();
    }
}

/// Destory the view and free the ViewStack node holding it.
pub fn destroy(self: *const Self) void {
    self.deinit();
    const node = @fieldParentPtr(ViewStack(Self).Node, "view", self);
    util.gpa.destroy(node);
}
