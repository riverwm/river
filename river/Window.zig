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

const Window = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const posix = std.posix;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const ForeignToplevelHandle = @import("ForeignToplevelHandle.zig");
const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Seat = @import("Seat.zig");
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandWindow = @import("XwaylandWindow.zig");

const log = std.log.scoped(.window);

pub const Constraints = struct {
    min_width: u31 = 1,
    max_width: u31 = math.maxInt(u31),
    min_height: u31 = 1,
    max_height: u31 = math.maxInt(u31),
};

const Impl = union(enum) {
    toplevel: XdgToplevel,
    xwayland_window: if (build_options.xwayland) XwaylandWindow else noreturn,
    /// This state is assigned during destruction after the xdg toplevel
    /// has been destroyed but while the transaction system is still rendering
    /// saved surfaces of the window.
    /// The toplevel could simply be set to undefined instead, but using a
    /// tag like this gives us better safety checks.
    none,
};

pub const State = struct {
    /// The output-relative coordinates of the window and dimensions requested by river.
    box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    /// Number of seats currently focusing the window
    focus: u32 = 0,

    fullscreen: bool = false,
    urgent: bool = false,
    ssd: bool = false,
    resizing: bool = false,
};

/// The window management protocol object for this window
/// If the window is unmapped the "closed" event is sent to the current object.
/// If the window is remapped a new object is created and sent to the window manager.
object: ?*river.WindowV1,

/// The implementation of this window
impl: Impl,

/// Link for WindowManager.windows
link: wl.list.Link,
/// Link for WindowManager.pending_to_wm.new_windows
link_new: wl.list.Link,

tree: *wlr.SceneTree,
surface_tree: *wlr.SceneTree,
saved_surface_tree: *wlr.SceneTree,
/// Order is left, right, top, bottom
borders: [4]*wlr.SceneRect,
popup_tree: *wlr.SceneTree,

/// Bounds on the width/height of the window, set by the toplevel/xwayland_window implementation.
constraints: Constraints = .{},

mapped: bool = false,
/// This is true if the Window is involved in the currently inflight transaction.
inflight_transaction: bool = false,
/// This indicates that the window should be destroyed when the current
/// transaction completes. See Window.destroy()
destroying: bool = false,

pending: struct {
    box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    decoration_hint: river.WindowV1.DecorationHint = .only_supports_csd,
    /// TODO output hint
    fullscreen_requested: bool = false,

    resizing: bool = false,
} = .{},

uncommitted: struct {} = .{},
uncommitted_render_list_link: wl.list.Link,

committed: struct {} = .{},
committed_render_list_link: wl.list.Link,

inflight: State = .{},
inflight_render_list_link: wl.list.Link,

/// The current state represented by the scene graph.
current: State = .{},

foreign_toplevel_handle: ForeignToplevelHandle = .{},

pub fn create(impl: Impl) error{OutOfMemory}!*Window {
    assert(impl != .none);

    const window = try util.gpa.create(Window);
    errdefer util.gpa.destroy(window);

    const object = blk: {
        const wm_v1 = server.wm.object orelse break :blk null;
        break :blk river.WindowV1.create(wm_v1.getClient(), wm_v1.getVersion(), 0) catch
            return error.OutOfMemory;
    };
    errdefer if (object) |o| o.destroy();

    const tree = try server.root.hidden_tree.createSceneTree();
    errdefer tree.node.destroy();

    const popup_tree = try server.root.hidden_tree.createSceneTree();
    errdefer popup_tree.node.destroy();

    window.* = .{
        .object = object,
        .impl = impl,
        .link = undefined,
        .link_new = undefined,
        .tree = tree,
        .surface_tree = try tree.createSceneTree(),
        .saved_surface_tree = try tree.createSceneTree(),
        .borders = .{
            try tree.createSceneRect(0, 0, &server.config.border_color),
            try tree.createSceneRect(0, 0, &server.config.border_color),
            try tree.createSceneRect(0, 0, &server.config.border_color),
            try tree.createSceneRect(0, 0, &server.config.border_color),
        },
        .popup_tree = popup_tree,

        .uncommitted_render_list_link = undefined,
        .committed_render_list_link = undefined,
        .inflight_render_list_link = undefined,
    };

    server.wm.windows.prepend(window);
    server.wm.pending.new_windows.prepend(window);

    window.uncommitted_render_list_link.init();
    window.committed_render_list_link.init();
    window.inflight_render_list_link.init();

    window.tree.node.setEnabled(false);
    window.popup_tree.node.setEnabled(false);
    window.saved_surface_tree.node.setEnabled(false);

    try SceneNodeData.attach(&window.tree.node, .{ .window = window });
    try SceneNodeData.attach(&window.popup_tree.node, .{ .window = window });

    return window;
}

/// If saved buffers of the window are currently in use by a transaction,
/// mark this window for destruction when the transaction completes. Otherwise
/// destroy immediately.
pub fn destroy(window: *Window, when: enum { lazy, assert }) void {
    assert(window.impl == .none);
    assert(!window.mapped);

    window.destroying = true;

    // If there are still saved buffers, then this window needs to be kept
    // around until the current transaction completes. This function will be
    // called again in Root.commitTransaction()
    if (!window.saved_surface_tree.node.enabled) {
        window.tree.node.destroy();
        window.popup_tree.node.destroy();

        window.link.remove();
        window.link_new.remove();
        window.uncommitted_render_list_link.remove();
        window.committed_render_list_link.remove();
        window.inflight_render_list_link.remove();

        // XXX destroy object?

        util.gpa.destroy(window);
    } else {
        switch (when) {
            .lazy => {},
            .assert => unreachable,
        }
    }
}

/// The change in x/y position of the window during resize cannot be determined
/// until the size of the buffer actually committed is known. Clients are permitted
/// by the protocol to take a size smaller than that requested by the compositor in
/// order to maintain an aspect ratio or similar (mpv does this for example).
pub fn resizeUpdatePosition(window: *Window, width: i32, height: i32) void {
    assert(window.inflight.resizing);

    const data = blk: {
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) {
            const cursor = &node.data.cursor;
            if (cursor.inflight_mode == .resize and cursor.inflight_mode.resize.window == window) {
                break :blk cursor.inflight_mode.resize;
            }
        } else {
            // The window resizing state should never be set when the window is
            // not the target of an interactive resize.
            unreachable;
        }
    };

    if (data.edges.left) {
        window.inflight.box.x += window.current.box.width - width;
        window.pending.box.x = window.inflight.box.x;
    }

    if (data.edges.top) {
        window.inflight.box.y += window.current.box.height - height;
        window.pending.box.y = window.inflight.box.y;
    }
}

pub fn commitTransaction(window: *Window) void {
    assert(window.inflight_transaction);
    window.inflight_transaction = false;

    window.foreign_toplevel_handle.update();

    window.dropSavedSurfaceTree();

    switch (window.impl) {
        .toplevel => |*toplevel| {
            switch (toplevel.configure_state) {
                .inflight, .acked => {
                    switch (toplevel.configure_state) {
                        .inflight => |serial| toplevel.configure_state = .{ .timed_out = serial },
                        .acked => toplevel.configure_state = .timed_out_acked,
                        else => unreachable,
                    }

                    // The transaction has timed out for the xdg toplevel, which means a commit
                    // in response to the configure with the inflight width/height has not yet
                    // been made. It may seem that we should therefore leave the current.box
                    // width/height unchanged. However, this would in fact cause visual glitches.
                    //
                    // We must update the dimensions to the current geometry of the
                    // xdg toplevel here in order to handle the following series of events:
                    //
                    // 0. initial state: client has dimensions X
                    // 1. transaction A sends a configure of size Y
                    // 2. transaction A times out - saved surfaces are dropped
                    // 3. transaction B sends a configure of size Z
                    // 4. client commits buffer of size Y
                    // 5. transaction B times out - saved surfaces are dropped
                    //
                    // If we did not use the current geometry of the toplevel at this point
                    // we would be rendering the SSD border at initial size X but the surface
                    // would be rendered at size Y.
                    if (window.inflight.resizing) {
                        window.resizeUpdatePosition(toplevel.geometry.width, toplevel.geometry.height);
                    }

                    window.current = window.inflight;
                    window.current.box.width = toplevel.geometry.width;
                    window.current.box.height = toplevel.geometry.height;
                },
                .idle, .committed => {
                    toplevel.configure_state = .idle;
                    window.current = window.inflight;
                },
                .timed_out, .timed_out_acked => unreachable,
            }
        },
        .xwayland_window => |xwayland_window| {
            if (window.inflight.resizing) {
                window.resizeUpdatePosition(
                    xwayland_window.xwayland_surface.width,
                    xwayland_window.xwayland_surface.height,
                );
            }

            window.inflight.box.width = xwayland_window.xwayland_surface.width;
            window.inflight.box.height = xwayland_window.xwayland_surface.height;
            window.pending.box.width = xwayland_window.xwayland_surface.width;
            window.pending.box.height = xwayland_window.xwayland_surface.height;

            window.current = window.inflight;
        },
        // This may seem pointless at first glance, but is in fact necessary
        // to prevent an assertion failure in Root.commitTransaction() as that
        // function assumes that the inflight tags/output will be applied by
        // Window.commitTransaction() even for windows being destroyed.
        .none => window.current = window.inflight,
    }

    window.updateSceneState();
}

pub fn updateSceneState(window: *Window) void {
    const box = &window.current.box;
    window.tree.node.setPosition(box.x, box.y);
    window.popup_tree.node.setPosition(box.x, box.y);

    {
        const config = &server.config;
        const border_width: c_int = config.border_width;
        const border_color = &config.border_color;

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

        for (&window.borders, &border_boxes) |border, *border_box| {
            border.node.setEnabled(window.current.ssd and !window.current.fullscreen);
            border.node.setPosition(border_box.x, border_box.y);
            border.setSize(border_box.width, border_box.height);
            border.setColor(border_color);
        }
    }
}

/// Returns true if the configure should be waited for by the transaction system.
pub fn configure(window: *Window) bool {
    assert(window.mapped and !window.destroying);
    switch (window.impl) {
        .toplevel => |*toplevel| return toplevel.configure(),
        .xwayland_window => |*xwayland_window| return xwayland_window.configure(),
        .none => unreachable,
    }
}

/// Returns null if the window is currently being destroyed and no longer has
/// an associated surface.
/// May also return null for Xwayland windows that are not currently mapped.
pub fn rootSurface(window: Window) ?*wlr.Surface {
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.base.surface,
        .xwayland_window => |xwayland_window| xwayland_window.xwayland_surface.surface,
        .none => null,
    };
}

pub fn sendFrameDone(window: Window) void {
    assert(window.mapped and !window.destroying);

    var now: posix.timespec = undefined;
    posix.clock_gettime(posix.CLOCK.MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
    window.rootSurface().?.sendFrameDone(&now);
}

pub fn dropSavedSurfaceTree(window: *Window) void {
    if (!window.saved_surface_tree.node.enabled) return;

    var it = window.saved_surface_tree.children.safeIterator(.forward);
    while (it.next()) |node| node.destroy();

    window.saved_surface_tree.node.setEnabled(false);
    window.surface_tree.node.setEnabled(true);
}

pub fn saveSurfaceTree(window: *Window) void {
    assert(!window.saved_surface_tree.node.enabled);
    assert(window.saved_surface_tree.children.empty());

    window.surface_tree.node.forEachBuffer(*wlr.SceneTree, saveSurfaceTreeIter, window.saved_surface_tree);

    window.surface_tree.node.setEnabled(false);
    window.saved_surface_tree.node.setEnabled(true);
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

pub fn close(window: Window) void {
    switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.sendClose(),
        .xwayland_window => |xwayland_window| xwayland_window.xwayland_surface.close(),
        .none => {},
    }
}

pub fn destroyPopups(window: Window) void {
    switch (window.impl) {
        .toplevel => |toplevel| toplevel.destroyPopups(),
        .xwayland_window, .none => {},
    }
}

/// Return the current title of the window if any.
pub fn getTitle(window: Window) ?[*:0]const u8 {
    assert(!window.destroying);
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.title,
        .xwayland_window => |xwayland_window| xwayland_window.xwayland_surface.title,
        .none => unreachable,
    };
}

/// Return the current app_id of the window if any.
pub fn getAppId(window: Window) ?[*:0]const u8 {
    assert(!window.destroying);
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.app_id,
        // X11 clients don't have an app_id but the class serves a similar role.
        .xwayland_window => |xwayland_window| xwayland_window.xwayland_surface.class,
        .none => unreachable,
    };
}

/// Clamp the width/height of the box to the constraints of the window
pub fn applyConstraints(window: *Window, box: *wlr.Box) void {
    box.width = math.clamp(box.width, window.constraints.min_width, window.constraints.max_width);
    box.height = math.clamp(box.height, window.constraints.min_height, window.constraints.max_height);
}

/// Called by the impl when the surface is ready to be displayed
pub fn map(window: *Window) !void {
    log.debug("window '{?s}' mapped", .{window.getTitle()});

    assert(!window.mapped and !window.destroying);
    window.mapped = true;

    window.foreign_toplevel_handle.map();

    server.wm.applyPending();
}

/// Called by the impl when the surface will no longer be displayed
pub fn unmap(window: *Window) void {
    log.debug("window '{?s}' unmapped", .{window.getTitle()});

    if (!window.saved_surface_tree.node.enabled) window.saveSurfaceTree();

    //window.pending_render_list_link.remove();
    //server.root.hidden.pending.render_list.prepend(window);

    assert(window.mapped and !window.destroying);
    window.mapped = false;

    window.foreign_toplevel_handle.unmap();

    server.wm.applyPending();
}

pub fn notifyTitle(window: *const Window) void {
    if (window.foreign_toplevel_handle.wlr_handle) |wlr_handle| {
        if (window.getTitle()) |title| wlr_handle.setTitle(title);
    }
}

pub fn notifyAppId(window: Window) void {
    if (window.foreign_toplevel_handle.wlr_handle) |wlr_handle| {
        if (window.getAppId()) |app_id| wlr_handle.setAppId(app_id);
    }
}
