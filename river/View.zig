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

const ForeignToplevelHandle = @import("ForeignToplevelHandle.zig");
const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Seat = @import("Seat.zig");
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandView = @import("XwaylandView.zig");

const log = std.log.scoped(.view);

pub const Constraints = struct {
    min_width: u31 = 1,
    max_width: u31 = math.maxInt(u31),
    min_height: u31 = 1,
    max_height: u31 = math.maxInt(u31),
};

const Impl = union(enum) {
    xdg_toplevel: XdgToplevel,
    xwayland_view: if (build_options.xwayland) XwaylandView else noreturn,
    /// This state is assigned during destruction after the xdg toplevel
    /// has been destroyed but while the transaction system is still rendering
    /// saved surfaces of the view.
    /// The xdg_toplevel could simply be set to undefined instead, but using a
    /// tag like this gives us better safety checks.
    none,
};

pub const State = struct {
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
    ssd: bool = false,
    resizing: bool = false,

    /// Modify the x/y of the given state by delta_x/delta_y, clamping to the
    /// bounds of the output.
    pub fn move(state: *State, delta_x: i32, delta_y: i32) void {
        const border_width = if (state.ssd) server.config.border_width else 0;

        var output_width: i32 = math.maxInt(i32);
        var output_height: i32 = math.maxInt(i32);
        if (state.output) |output| {
            output.wlr_output.effectiveResolution(&output_width, &output_height);
        }

        const max_x = output_width - state.box.width - border_width;
        state.box.x += delta_x;
        state.box.x = @max(state.box.x, border_width);
        state.box.x = @min(state.box.x, max_x);
        state.box.x = @max(state.box.x, 0);

        const max_y = output_height - state.box.height - border_width;
        state.box.y += delta_y;
        state.box.y = @max(state.box.y, border_width);
        state.box.y = @min(state.box.y, max_y);
        state.box.y = @max(state.box.y, 0);
    }

    pub fn clampToOutput(state: *State) void {
        const output = state.output orelse return;

        var output_width: i32 = undefined;
        var output_height: i32 = undefined;
        output.wlr_output.effectiveResolution(&output_width, &output_height);

        const border_width = if (state.ssd) server.config.border_width else 0;
        state.box.width = @min(state.box.width, output_width - (2 * border_width));
        state.box.height = @min(state.box.height, output_height - (2 * border_width));

        state.move(0, 0);
    }
};

/// The implementation of this view
impl: Impl,

/// Link for Root.views
link: wl.list.Link,

tree: *wlr.SceneTree,
surface_tree: *wlr.SceneTree,
saved_surface_tree: *wlr.SceneTree,
/// Order is left, right, top, bottom
borders: [4]*wlr.SceneRect,
popup_tree: *wlr.SceneTree,

/// Bounds on the width/height of the view, set by the xdg_toplevel/xwayland_view implementation.
constraints: Constraints = .{},

mapped: bool = false,
/// This is true if the View is involved in the currently inflight transaction.
inflight_transaction: bool = false,
/// This indicates that the view should be destroyed when the current
/// transaction completes. See View.destroy()
destroying: bool = false,

/// The state of the view that is directly acted upon/modified through user input.
///
/// Pending state will be copied to the inflight state and communicated to clients
/// to be applied as a single atomic transaction across all clients as soon as any
/// in progress transaction has been completed.
///
/// Any time pending state is modified Root.applyPending() must be called
/// before yielding back to the event loop.
pending: State = .{},
pending_focus_stack_link: wl.list.Link,
pending_wm_stack_link: wl.list.Link,

/// The state most recently sent to the layout generator and clients.
/// This state is immutable until all clients have replied and the transaction
/// is completed, at which point this inflight state is copied to current.
inflight: State = .{},
inflight_focus_stack_link: wl.list.Link,
inflight_wm_stack_link: wl.list.Link,

/// The current state represented by the scene graph.
current: State = .{},

/// The floating dimensions the view, saved so that they can be restored if the
/// view returns to floating mode.
float_box: wlr.Box = undefined,

/// This state exists purely to allow for more intuitive behavior when
/// exiting fullscreen if there is no active layout.
post_fullscreen_box: wlr.Box = undefined,

foreign_toplevel_handle: ForeignToplevelHandle = .{},

pub fn create(impl: Impl) error{OutOfMemory}!*Self {
    assert(impl != .none);

    const view = try util.gpa.create(Self);
    errdefer util.gpa.destroy(view);

    const tree = try server.root.hidden.tree.createSceneTree();
    errdefer tree.node.destroy();

    const popup_tree = try server.root.hidden.tree.createSceneTree();
    errdefer popup_tree.node.destroy();

    view.* = .{
        .impl = impl,
        .link = undefined,
        .tree = tree,
        .surface_tree = try tree.createSceneTree(),
        .saved_surface_tree = try tree.createSceneTree(),
        .borders = .{
            try tree.createSceneRect(0, 0, &server.config.border_color_unfocused),
            try tree.createSceneRect(0, 0, &server.config.border_color_unfocused),
            try tree.createSceneRect(0, 0, &server.config.border_color_unfocused),
            try tree.createSceneRect(0, 0, &server.config.border_color_unfocused),
        },
        .popup_tree = popup_tree,

        .pending_wm_stack_link = undefined,
        .pending_focus_stack_link = undefined,
        .inflight_wm_stack_link = undefined,
        .inflight_focus_stack_link = undefined,
    };

    server.root.views.prepend(view);
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
    assert(view.impl == .none);

    view.destroying = true;

    // If there are still saved buffers, then this view needs to be kept
    // around until the current transaction completes. This function will be
    // called again in Root.commitTransaction()
    if (!view.saved_surface_tree.node.enabled) {
        view.tree.node.destroy();
        view.popup_tree.node.destroy();

        view.link.remove();
        view.pending_focus_stack_link.remove();
        view.pending_wm_stack_link.remove();
        view.inflight_focus_stack_link.remove();
        view.inflight_wm_stack_link.remove();

        util.gpa.destroy(view);
    }
}

/// The change in x/y position of the view during resize cannot be determined
/// until the size of the buffer actually committed is known. Clients are permitted
/// by the protocol to take a size smaller than that requested by the compositor in
/// order to maintain an aspect ratio or similar (mpv does this for example).
pub fn resizeUpdatePosition(view: *Self, width: i32, height: i32) void {
    assert(view.inflight.resizing);

    const data = blk: {
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) {
            const cursor = &node.data.cursor;
            if (cursor.inflight_mode == .resize and cursor.inflight_mode.resize.view == view) {
                break :blk cursor.inflight_mode.resize;
            }
        } else {
            // The view resizing state should never be set when the view is
            // not the target of an interactive resize.
            unreachable;
        }
    };

    if (data.edges.left) {
        view.inflight.box.x += view.current.box.width - width;
        view.pending.box.x = view.inflight.box.x;
    }

    if (data.edges.top) {
        view.inflight.box.y += view.current.box.height - height;
        view.pending.box.y = view.inflight.box.y;
    }
}

pub fn commitTransaction(view: *Self) void {
    assert(view.inflight_transaction);
    view.inflight_transaction = false;

    view.foreign_toplevel_handle.update();

    // Tag and output changes must be applied immediately even if the configure sequence times out.
    // This allows Root.commitTransaction() to rely on the fact that all tag and output changes
    // are applied directly by this function.
    view.current.tags = view.inflight.tags;
    view.current.output = view.inflight.output;

    view.dropSavedSurfaceTree();

    switch (view.impl) {
        .xdg_toplevel => |*xdg_toplevel| {
            switch (xdg_toplevel.configure_state) {
                .inflight => |serial| {
                    xdg_toplevel.configure_state = .{ .timed_out = serial };
                },
                .acked => {
                    xdg_toplevel.configure_state = .timed_out_acked;
                },
                .idle, .committed => {
                    xdg_toplevel.configure_state = .idle;
                    view.updateCurrent();
                },
                .timed_out, .timed_out_acked => unreachable,
            }
        },
        .xwayland_view => |xwayland_view| {
            if (view.inflight.resizing) {
                view.resizeUpdatePosition(
                    xwayland_view.xwayland_surface.width,
                    xwayland_view.xwayland_surface.height,
                );
            }

            view.inflight.box.width = xwayland_view.xwayland_surface.width;
            view.inflight.box.height = xwayland_view.xwayland_surface.height;
            view.pending.box.width = xwayland_view.xwayland_surface.width;
            view.pending.box.height = xwayland_view.xwayland_surface.height;

            view.updateCurrent();
        },
        .none => {},
    }
}

pub fn updateCurrent(view: *Self) void {
    view.current = view.inflight;

    const box = &view.current.box;
    view.tree.node.setPosition(box.x, box.y);
    view.popup_tree.node.setPosition(box.x, box.y);

    var output_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    if (view.current.output) |output| {
        output.wlr_output.effectiveResolution(&output_box.width, &output_box.height);
    }

    {
        var surface_clip: wlr.Box = output_box;

        // The clip is applied relative to the root node of the subsurface tree.
        surface_clip.x -= box.x;
        surface_clip.y -= box.y;

        switch (view.impl) {
            .xdg_toplevel => |xdg_toplevel| {
                surface_clip.x += xdg_toplevel.geometry.x;
                surface_clip.y += xdg_toplevel.geometry.y;
            },
            .xwayland_view, .none => {},
        }

        if (!view.surface_tree.children.empty()) {
            view.surface_tree.node.subsurfaceTreeSetClip(&surface_clip);
        }
    }

    {
        const config = &server.config;
        const border_width: c_int = config.border_width;
        const border_color = blk: {
            if (view.current.urgent) break :blk &config.border_color_urgent;
            if (view.current.focus != 0) break :blk &config.border_color_focused;
            break :blk &config.border_color_unfocused;
        };

        // Order is left, right, top, bottom
        // left and right borders include the corners, top and bottom do not.
        var border_boxes = [4]wlr.Box{
            .{
                .x = -border_width,
                .y = -border_width,
                .width = border_width,
                .height = box.height + 2 * border_width,
            },
            .{
                .x = box.width,
                .y = -border_width,
                .width = border_width,
                .height = box.height + 2 * border_width,
            },
            .{
                .x = 0,
                .y = -border_width,
                .width = box.width,
                .height = border_width,
            },
            .{
                .x = 0,
                .y = box.height,
                .width = box.width,
                .height = border_width,
            },
        };

        for (&view.borders, &border_boxes) |border, *border_box| {
            border_box.x += box.x;
            border_box.y += box.y;
            _ = border_box.intersection(border_box, &output_box);
            border_box.x -= box.x;
            border_box.y -= box.y;

            border.node.setEnabled(view.current.ssd and !view.current.fullscreen);
            border.node.setPosition(border_box.x, border_box.y);
            border.setSize(border_box.width, border_box.height);
            border.setColor(border_color);
        }
    }
}

/// Returns true if the configure should be waited for by the transaction system.
pub fn configure(self: *Self) bool {
    assert(self.mapped and !self.destroying);
    switch (self.impl) {
        .xdg_toplevel => |*xdg_toplevel| return xdg_toplevel.configure(),
        .xwayland_view => |*xwayland_view| return xwayland_view.configure(),
        .none => unreachable,
    }
}

pub fn rootSurface(self: Self) *wlr.Surface {
    assert(self.mapped and !self.destroying);
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.rootSurface(),
        .xwayland_view => |xwayland_view| xwayland_view.rootSurface(),
        .none => unreachable,
    };
}

pub fn sendFrameDone(self: Self) void {
    assert(self.mapped and !self.destroying);
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

    switch (output.attachMode()) {
        .top => output.pending.wm_stack.prepend(view),
        .bottom => output.pending.wm_stack.append(view),
        .after => |n| view.attachAfter(&output.pending, n),
    }
    output.pending.focus_stack.prepend(view);

    if (view.pending.fullscreen) {
        view.pending.box = .{ .x = 0, .y = 0, .width = undefined, .height = undefined };
        output.wlr_output.effectiveResolution(&view.pending.box.width, &view.pending.box.height);
    } else if (view.pending.float) {
        view.pending.clampToOutput();
    }
}

pub fn close(self: Self) void {
    assert(!self.destroying);
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.close(),
        .xwayland_view => |xwayland_view| xwayland_view.close(),
        .none => unreachable,
    }
}

pub fn destroyPopups(self: Self) void {
    assert(!self.destroying);
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.destroyPopups(),
        .xwayland_view => {},
        .none => unreachable,
    }
}

/// Return the current title of the view if any.
pub fn getTitle(self: Self) ?[*:0]const u8 {
    assert(!self.destroying);
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.getTitle(),
        .xwayland_view => |xwayland_view| xwayland_view.getTitle(),
        .none => unreachable,
    };
}

/// Return the current app_id of the view if any.
pub fn getAppId(self: Self) ?[*:0]const u8 {
    assert(!self.destroying);
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.getAppId(),
        .xwayland_view => |xwayland_view| xwayland_view.getAppId(),
        .none => unreachable,
    };
}

/// Clamp the width/height of the box to the constraints of the view
pub fn applyConstraints(self: *Self, box: *wlr.Box) void {
    box.width = math.clamp(box.width, self.constraints.min_width, self.constraints.max_width);
    box.height = math.clamp(box.height, self.constraints.min_height, self.constraints.max_height);
}

/// Attach after n visible, not-floating views in the pending wm_stack
pub fn attachAfter(view: *Self, pending_state: *Output.PendingState, n: usize) void {
    var visible: u32 = 0;
    var it = pending_state.wm_stack.iterator(.forward);

    while (it.next()) |other| {
        if (visible >= n) break;
        if (!other.pending.float and other.pending.tags & pending_state.tags != 0) {
            visible += 1;
        }
    }

    it.current.prev.?.insert(&view.pending_wm_stack_link);
}

/// Called by the impl when the surface is ready to be displayed
pub fn map(view: *Self) !void {
    log.debug("view '{?s}' mapped", .{view.getTitle()});

    assert(!view.mapped and !view.destroying);
    view.mapped = true;

    view.foreign_toplevel_handle.map();

    if (server.config.rules.float.match(view)) |float| {
        view.pending.float = float;
    }
    if (server.config.rules.fullscreen.match(view)) |fullscreen| {
        view.pending.fullscreen = fullscreen;
    }
    if (server.config.rules.ssd.match(view)) |ssd| {
        view.pending.ssd = ssd;
    }

    if (server.config.rules.dimensions.match(view)) |dimensions| {
        view.pending.box.width = dimensions.width;
        view.pending.box.height = dimensions.height;
    }

    const output = try server.config.outputRuleMatch(view) orelse
        server.input_manager.defaultSeat().focused_output;

    if (server.config.rules.position.match(view)) |position| {
        view.pending.box.x = position.x;
        view.pending.box.y = position.y;
    } else if (output) |o| {
        // Center the initial pending box on the output
        view.pending.box.x = @divTrunc(@max(0, o.usable_box.width - view.pending.box.width), 2);
        view.pending.box.y = @divTrunc(@max(0, o.usable_box.height - view.pending.box.height), 2);
    }

    view.pending.tags = blk: {
        const default = if (output) |o| o.pending.tags else server.root.fallback_pending.tags;
        if (server.config.rules.tags.match(view)) |tags| break :blk tags;
        const tags = default & server.config.spawn_tagmask;
        break :blk if (tags != 0) tags else default;
    };

    if (output) |o| {
        view.setPendingOutput(o);

        var it = server.input_manager.seats.first;
        while (it) |seat_node| : (it = seat_node.next) seat_node.data.focus(view);
    } else {
        log.debug("no output available for newly mapped view, adding to fallback stacks", .{});

        view.pending_wm_stack_link.remove();
        view.pending_focus_stack_link.remove();

        switch (server.config.default_attach_mode) {
            .top => server.root.fallback_pending.wm_stack.prepend(view),
            .bottom => server.root.fallback_pending.wm_stack.append(view),
            .after => |n| view.attachAfter(&server.root.fallback_pending, n),
        }
        server.root.fallback_pending.focus_stack.prepend(view);

        view.inflight_wm_stack_link.remove();
        view.inflight_wm_stack_link.init();

        view.inflight_focus_stack_link.remove();
        view.inflight_focus_stack_link.init();
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

    assert(view.mapped and !view.destroying);
    view.mapped = false;

    view.foreign_toplevel_handle.unmap();

    server.root.applyPending();
}

pub fn notifyTitle(view: *const Self) void {
    if (view.foreign_toplevel_handle.wlr_handle) |wlr_handle| {
        if (view.getTitle()) |title| wlr_handle.setTitle(title);
    }
    // Send title to all status listeners attached to a seat which focuses this view
    var seat_it = server.input_manager.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        if (seat_node.data.focused == .view and seat_node.data.focused.view == view) {
            var client_it = seat_node.data.status_trackers.first;
            while (client_it) |client_node| : (client_it = client_node.next) {
                client_node.data.sendFocusedView();
            }
        }
    }
}

pub fn notifyAppId(view: Self) void {
    if (view.foreign_toplevel_handle.wlr_handle) |wlr_handle| {
        if (view.getAppId()) |app_id| wlr_handle.setAppId(app_id);
    }
}
