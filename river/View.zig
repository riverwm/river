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

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const os = std.os;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Seat = @import("Seat.zig");
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandView = @import("XwaylandView.zig");

const log = std.log.scoped(.view);

pub const Constraints = struct {
    min_width: u31,
    max_width: u31,
    min_height: u31,
    max_height: u31,
};

const Impl = union(enum) {
    xdg_toplevel: XdgToplevel,
    xwayland_view: if (build_options.xwayland) XwaylandView else noreturn,
};

const State = struct {
    /// The output the view is currently assigned to.
    /// May be null if there are no outputs or for newly created views.
    /// Must be set using setPendingOutput()
    output: ?*Output = null,

    /// The output-relative coordinates of the view and dimensions requested by river.
    box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    /// The tags of the view, as a bitmask
    tags: u32 = 0,

    /// Number of seats currently focusing the view
    focus: u32 = 0,

    float: bool = false,
    fullscreen: bool = false,
    urgent: bool = false,
};

/// The implementation of this view
impl: Impl,

tree: *wlr.SceneTree,
surface_tree: *wlr.SceneTree,
saved_surface_tree: *wlr.SceneTree,
borders: struct {
    left: *wlr.SceneRect,
    right: *wlr.SceneRect,
    top: *wlr.SceneRect,
    bottom: *wlr.SceneRect,
},
popup_tree: *wlr.SceneTree,

/// This indicates that the view should be destroyed when the current
/// transaction completes. See View.destroy()
destroying: bool = false,

pending: State = .{},
pending_focus_stack_link: wl.list.Link,
pending_wm_stack_link: wl.list.Link,

inflight: State = .{},
inflight_focus_stack_link: wl.list.Link,
inflight_wm_stack_link: wl.list.Link,

current: State = .{},

/// The serial sent with the currently inflight configure event
inflight_serial: ?u32 = null,

/// The floating dimensions the view, saved so that they can be restored if the
/// view returns to floating mode.
float_box: wlr.Box = undefined,

/// This state exists purely to allow for more intuitive behavior when
/// exiting fullscreen if there is no active layout.
post_fullscreen_box: wlr.Box = undefined,

draw_borders: bool = true,

request_activate: wl.Listener(*wlr.XdgActivationV1.event.RequestActivate) =
    wl.Listener(*wlr.XdgActivationV1.event.RequestActivate).init(handleRequestActivate),

pub fn create(impl: Impl) error{OutOfMemory}!*Self {
    const view = try util.gpa.create(Self);
    errdefer util.gpa.destroy(view);

    const tree = try server.root.hidden.tree.createSceneTree();
    errdefer tree.node.destroy();

    const popup_tree = try server.root.hidden.tree.createSceneTree();
    errdefer popup_tree.node.destroy();

    view.* = .{
        .impl = impl,
        .tree = tree,
        .surface_tree = try tree.createSceneTree(),
        .saved_surface_tree = try tree.createSceneTree(),
        .borders = .{
            .left = try tree.createSceneRect(0, 0, &server.config.border_color_unfocused),
            .right = try tree.createSceneRect(0, 0, &server.config.border_color_unfocused),
            .top = try tree.createSceneRect(0, 0, &server.config.border_color_unfocused),
            .bottom = try tree.createSceneRect(0, 0, &server.config.border_color_unfocused),
        },
        .popup_tree = popup_tree,

        .pending_wm_stack_link = undefined,
        .pending_focus_stack_link = undefined,
        .inflight_wm_stack_link = undefined,
        .inflight_focus_stack_link = undefined,
    };

    server.root.hidden.pending.focus_stack.prepend(view);
    server.root.hidden.pending.wm_stack.prepend(view);
    server.root.hidden.inflight.focus_stack.prepend(view);
    server.root.hidden.inflight.wm_stack.prepend(view);

    view.tree.node.setEnabled(false);
    view.popup_tree.node.setEnabled(false);
    view.saved_surface_tree.node.setEnabled(false);

    try SceneNodeData.attach(&view.tree.node, .{ .view = view });
    try SceneNodeData.attach(&view.popup_tree.node, .{ .view = view });

    return view;
}

/// If saved buffers of the view are currently in use by a transaction,
/// mark this view for destruction when the transaction completes. Otherwise
/// destroy immediately.
pub fn destroy(view: *Self) void {
    view.destroying = true;

    // If there are still saved buffers, then this view needs to be kept
    // around until the current transaction completes. This function will be
    // called again in Root.commitTransaction()
    if (!view.saved_surface_tree.node.enabled) {
        view.tree.node.destroy();
        view.popup_tree.node.destroy();

        view.pending_focus_stack_link.remove();
        view.pending_wm_stack_link.remove();
        view.inflight_focus_stack_link.remove();
        view.inflight_wm_stack_link.remove();

        util.gpa.destroy(view);
    }
}

pub fn updateCurrent(view: *Self) void {
    const config = &server.config;

    view.current = view.inflight;
    view.dropSavedSurfaceTree();

    const color = blk: {
        if (view.current.urgent) break :blk &config.border_color_urgent;
        if (view.current.focus != 0) break :blk &config.border_color_focused;
        break :blk &config.border_color_unfocused;
    };

    const box = &view.current.box;
    view.tree.node.setPosition(box.x, box.y);
    view.popup_tree.node.setPosition(box.x, box.y);

    const enable_borders = view.draw_borders and !view.current.fullscreen;

    const border_width: c_int = config.border_width;
    view.borders.left.node.setEnabled(enable_borders);
    view.borders.left.node.setPosition(-border_width, -border_width);
    view.borders.left.setSize(border_width, box.height + 2 * border_width);
    view.borders.left.setColor(color);

    view.borders.right.node.setEnabled(enable_borders);
    view.borders.right.node.setPosition(box.width, -border_width);
    view.borders.right.setSize(border_width, box.height + 2 * border_width);
    view.borders.right.setColor(color);

    view.borders.top.node.setEnabled(enable_borders);
    view.borders.top.node.setPosition(0, -border_width);
    view.borders.top.setSize(box.width, border_width);
    view.borders.top.setColor(color);

    view.borders.bottom.node.setEnabled(enable_borders);
    view.borders.bottom.node.setPosition(0, box.height);
    view.borders.bottom.setSize(box.width, border_width);
    view.borders.bottom.setColor(color);
}

pub fn needsConfigure(self: Self) bool {
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.needsConfigure(),
        .xwayland_view => |xwayland_view| xwayland_view.needsConfigure(),
    };
}

pub fn configure(self: *Self) void {
    switch (self.impl) {
        .xdg_toplevel => |*xdg_toplevel| xdg_toplevel.configure(),
        .xwayland_view => |*xwayland_view| {
            // TODO(zig): remove this uneeded if statement
            // https://github.com/ziglang/zig/issues/13655
            if (build_options.xwayland) xwayland_view.configure();
        },
    }
}

pub fn rootSurface(self: Self) *wlr.Surface {
    assert(!self.destroying);
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.rootSurface(),
        .xwayland_view => |xwayland_view| xwayland_view.rootSurface(),
    };
}

pub fn sendFrameDone(self: Self) void {
    assert(!self.destroying);
    var now: os.timespec = undefined;
    os.clock_gettime(os.CLOCK.MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
    self.rootSurface().sendFrameDone(&now);
}

pub fn dropSavedSurfaceTree(self: *Self) void {
    if (!self.saved_surface_tree.node.enabled) return;

    var it = self.saved_surface_tree.children.safeIterator(.forward);
    while (it.next()) |node| node.destroy();

    self.saved_surface_tree.node.setEnabled(false);
    self.surface_tree.node.setEnabled(true);
}

pub fn saveSurfaceTree(self: *Self) void {
    assert(!self.saved_surface_tree.node.enabled);
    assert(self.saved_surface_tree.children.empty());

    self.surface_tree.node.forEachBuffer(*wlr.SceneTree, saveSurfaceTreeIter, self.saved_surface_tree);

    self.surface_tree.node.setEnabled(false);
    self.saved_surface_tree.node.setEnabled(true);
}

fn saveSurfaceTreeIter(
    buffer: *wlr.SceneBuffer,
    sx: c_int,
    sy: c_int,
    saved_surface_tree: *wlr.SceneTree,
) void {
    const saved = saved_surface_tree.createSceneBuffer(buffer.buffer) catch {
        log.err("out of memory", .{});
        return;
    };
    saved.node.setPosition(sx, sy);
    saved.setDestSize(buffer.dst_width, buffer.dst_height);
    saved.setSourceBox(&buffer.src_box);
    saved.setTransform(buffer.transform);
}

pub fn setPendingOutput(view: *Self, output: *Output) void {
    view.pending.output = output;
    view.pending_wm_stack_link.remove();
    view.pending_focus_stack_link.remove();

    switch (server.config.attach_mode) {
        .top => output.pending.wm_stack.prepend(view),
        .bottom => output.pending.wm_stack.append(view),
    }
    output.pending.focus_stack.prepend(view);

    // Adapt the floating position/dimensions of the view to the new output.
    if (view.pending.float) {
        var output_width: i32 = undefined;
        var output_height: i32 = undefined;
        output.wlr_output.effectiveResolution(&output_width, &output_height);

        const border_width = if (view.draw_borders) server.config.border_width else 0;
        view.pending.box.width = math.min(view.pending.box.width, output_width - (2 * border_width));
        view.pending.box.height = math.min(view.pending.box.height, output_height - (2 * border_width));

        view.move(0, 0);
    }
}

pub fn close(self: Self) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.close(),
        .xwayland_view => |xwayland_view| xwayland_view.close(),
    }
}

pub fn destroyPopups(self: Self) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.destroyPopups(),
        .xwayland_view => {},
    }
}

pub fn setActivated(self: Self, activated: bool) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.setActivated(activated),
        .xwayland_view => |xwayland_view| xwayland_view.setActivated(activated),
    }
}

pub fn setFullscreen(self: *Self, fullscreen: bool) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.setFullscreen(fullscreen),
        .xwayland_view => |*xwayland_view| {
            // TODO(zig): remove this uneeded if statement
            // https://github.com/ziglang/zig/issues/13655
            if (build_options.xwayland) xwayland_view.setFullscreen(fullscreen);
        },
    }
}

pub fn setResizing(self: Self, resizing: bool) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.setResizing(resizing),
        .xwayland_view => {},
    }
}

/// Iterates over all surfaces, subsurfaces, and popups in the tree
pub inline fn forEachSurface(
    self: Self,
    comptime T: type,
    comptime iterator: fn (surface: *wlr.Surface, sx: c_int, sy: c_int, data: T) void,
    user_data: T,
) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| {
            xdg_toplevel.xdg_toplevel.base.forEachSurface(T, iterator, user_data);
        },
        .xwayland_view => |xwayland_view| {
            xwayland_view.xwayland_surface.surface.?.forEachSurface(T, iterator, user_data);
        },
    }
}

/// Return the current title of the view if any.
pub fn getTitle(self: Self) ?[*:0]const u8 {
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.getTitle(),
        .xwayland_view => |xwayland_view| xwayland_view.getTitle(),
    };
}

/// Return the current app_id of the view if any.
pub fn getAppId(self: Self) ?[*:0]const u8 {
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.getAppId(),
        .xwayland_view => |xwayland_view| xwayland_view.getAppId(),
    };
}

/// Clamp the width/height of the box to the constraints of the view
pub fn applyConstraints(self: *Self, box: *wlr.Box) void {
    const constraints = self.getConstraints();
    box.width = math.clamp(box.width, constraints.min_width, constraints.max_width);
    box.height = math.clamp(box.height, constraints.min_height, constraints.max_height);
}

/// Return bounds on the dimensions of the view
pub fn getConstraints(self: Self) Constraints {
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.getConstraints(),
        .xwayland_view => |xwayland_view| xwayland_view.getConstraints(),
    };
}

/// Modify the pending x/y of the view by the given deltas, clamping to the
/// bounds of the output.
pub fn move(self: *Self, delta_x: i32, delta_y: i32) void {
    const border_width = if (self.draw_borders) server.config.border_width else 0;

    var output_width: i32 = math.maxInt(i32);
    var output_height: i32 = math.maxInt(i32);
    if (self.pending.output) |output| {
        output.wlr_output.effectiveResolution(&output_width, &output_height);
    }

    const max_x = output_width - self.pending.box.width - border_width;
    self.pending.box.x += delta_x;
    self.pending.box.x = math.max(self.pending.box.x, border_width);
    self.pending.box.x = math.min(self.pending.box.x, max_x);
    self.pending.box.x = math.max(self.pending.box.x, 0);

    const max_y = output_height - self.pending.box.height - border_width;
    self.pending.box.y += delta_y;
    self.pending.box.y = math.max(self.pending.box.y, border_width);
    self.pending.box.y = math.min(self.pending.box.y, max_y);
    self.pending.box.y = math.max(self.pending.box.y, 0);
}

/// Find and return the view corresponding to a given surface, if any
pub fn fromWlrSurface(surface: *wlr.Surface) ?*Self {
    if (surface.isXdgSurface()) {
        const xdg_surface = wlr.XdgSurface.fromWlrSurface(surface) orelse return null;
        if (xdg_surface.role == .toplevel) {
            return @intToPtr(*Self, xdg_surface.data);
        }
    }
    if (build_options.xwayland and surface.isXWaylandSurface()) {
        const xwayland_surface = wlr.XwaylandSurface.fromWlrSurface(surface) orelse return null;
        return @intToPtr(?*Self, xwayland_surface.data);
    }
    return null;
}

/// Called by the impl when the surface is ready to be displayed
pub fn map(view: *Self) !void {
    log.debug("view '{?s}' mapped", .{view.getTitle()});

    server.xdg_activation.events.request_activate.add(&view.request_activate);

    if (server.input_manager.defaultSeat().focused_output) |output| {
        // Center the initial pending box on the output
        view.pending.box.x = @divTrunc(math.max(0, output.usable_box.width - view.pending.box.width), 2);
        view.pending.box.y = @divTrunc(math.max(0, output.usable_box.height - view.pending.box.height), 2);

        view.pending.tags = blk: {
            const tags = output.pending.tags & server.config.spawn_tagmask;
            break :blk if (tags != 0) tags else output.pending.tags;
        };

        view.setPendingOutput(output);

        var it = server.input_manager.seats.first;
        while (it) |seat_node| : (it = seat_node.next) seat_node.data.focus(view);
    }

    view.float_box = view.pending.box;

    server.root.applyPending();
}

/// Called by the impl when the surface will no longer be displayed
pub fn unmap(view: *Self) void {
    log.debug("view '{?s}' unmapped", .{view.getTitle()});

    if (!view.saved_surface_tree.node.enabled) view.saveSurfaceTree();

    {
        view.pending.output = null;
        view.pending_focus_stack_link.remove();
        view.pending_wm_stack_link.remove();
        server.root.hidden.pending.focus_stack.prepend(view);
        server.root.hidden.pending.wm_stack.prepend(view);
    }

    {
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) {
            const seat = &node.data;
            if (seat.focused == .view and seat.focused.view == view) {
                seat.focus(null);
            }
        }
    }

    view.request_activate.link.remove();

    server.root.applyPending();
}

pub fn notifyTitle(self: *const Self) void {
    // Send title to all status listeners attached to a seat which focuses this view
    var seat_it = server.input_manager.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        if (seat_node.data.focused == .view and seat_node.data.focused.view == self) {
            var client_it = seat_node.data.status_trackers.first;
            while (client_it) |client_node| : (client_it = client_node.next) {
                client_node.data.sendFocusedView();
            }
        }
    }
}

pub fn notifyAppId(_: Self) void {
    // TODO reimplement foreign-toplevel-management I guess.
}

fn handleRequestActivate(
    _: *wl.Listener(*wlr.XdgActivationV1.event.RequestActivate),
    event: *wlr.XdgActivationV1.event.RequestActivate,
) void {
    if (fromWlrSurface(event.surface)) |view| {
        if (view.current.focus == 0) {
            view.pending.urgent = true;
            server.root.applyPending();
        }
    }
}
