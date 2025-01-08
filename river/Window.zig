// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020-2024 The River Developers
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
const meta = std.meta;
const posix = std.posix;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const Scene = @import("Scene.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Seat = @import("Seat.zig");
const WmNode = @import("WmNode.zig");
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandWindow = @import("XwaylandWindow.zig");

const log = std.log.scoped(.wm);

pub const DimensionsHint = struct {
    min_width: u31 = 0,
    max_width: u31 = 0,
    min_height: u31 = 0,
    max_height: u31 = 0,
};

const Impl = union(enum) {
    toplevel: XdgToplevel,
    xwayland: if (build_options.xwayland) XwaylandWindow else noreturn,
    /// This state is assigned during destruction after the xdg toplevel
    /// has been destroyed but while the transaction system is still rendering
    /// saved surfaces of the window.
    /// The toplevel could simply be set to undefined instead, but using a
    /// tag like this gives us better safety checks.
    none,
};

pub const Border = struct {
    edges: river.WindowV1.Edges = .{},
    width: u31 = 0,
    r: u32 = 0,
    b: u32 = 0,
    g: u32 = 0,
    a: u32 = 0,
};

pub const State = struct {
    width: ?u31 = null,
    height: ?u31 = null,
    hidden: bool = false,
    /// True if the window has keyboard focus from at least one seat.
    activated: bool = false,
    ssd: bool = false,
    border: Border = .{},
    tiled: river.WindowV1.Edges = .{},
    capabilities: river.WindowV1.Capabilities = .{},
    maximized: bool = false,
    fullscreen: bool = false,

    op: union(enum) {
        none,
        move: struct {
            seat: *Seat,
            start_x: i32,
            start_y: i32,
        },
        resize: struct {
            seat: *Seat,
            edges: river.WindowV1.Edges = .{},
            start_box: wlr.Box,
        },
    } = .none,
};

pub const WmState = struct {
    position: ?struct {
        x: i32,
        y: i32,
    } = null,
    dimensions: ?struct {
        width: u31,
        height: u31,
    } = null,
    hidden: bool = false,
    ssd: bool = false,
    border: Border = .{},
    tiled: river.WindowV1.Edges = .{},
    capabilities: river.WindowV1.Capabilities = .{
        .window_menu = true,
        .maximize = true,
        .fullscreen = true,
        .minimize = true,
    },
    maximized: bool = false,
    fullscreen: bool = false, // XXX output
    close: bool = false,
    op: union(enum) {
        none,
        move: struct {
            seat: *Seat,
        },
        resize: struct {
            seat: *Seat,
            edges: river.WindowV1.Edges = .{},
        },
    } = .none,
};

/// The window management protocol object for this window
/// Created after the window is ready to be configured.
/// Lifetime is managed through wm_pending.state
object: ?*river.WindowV1 = null,
node: WmNode,

/// The implementation of this window
impl: Impl,

tree: *wlr.SceneTree,
surfaces: Scene.SaveableSurfaces,

border: struct {
    left: *wlr.SceneRect,
    right: *wlr.SceneRect,
    top: *wlr.SceneRect,
    bottom: *wlr.SceneRect,
},
popup_tree: *wlr.SceneTree,

/// Set to true once the window manager client has made its first commit
/// proposing dimensions for a new river_window_v1 object.
initialized: bool = false,
mapped: bool = false,
/// This indicates that the window should be destroyed when the current
/// transaction completes. See Window.destroy()
destroying: bool = false,

/// WindowManager.windows
link: wl.list.Link,

/// State to be sent to the window manager client in the next update sequence.
wm_pending: struct {
    state: enum {
        /// Indicates that there is currently no associated river_window_v1
        /// object.
        init,
        /// Indicates that the window is ready to be configured.
        /// Create a river_window_v1 object if needed and send events.
        ready,
        /// Indicates that the closed event will be sent in the next update sequence.
        closing,
    } = .init,
    box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    dimensions_hint: DimensionsHint = .{},
    decoration_hint: river.WindowV1.DecorationHint = .only_supports_csd,
    /// Set back to no_request at the end of each update sequence
    fullscreen_requested: enum {
        no_request,
        /// TODO output hint
        fullscreen,
        exit,
    } = .no_request,
    dirty_app_id: bool = false,
    dirty_title: bool = false,
} = .{},

/// State sent to the window manager client in the latest update sequence.
/// This state is only kept around in order to avoid sending redundant events
/// to the window manager client.
wm_sent: struct {
    position: ?struct { x: i32, y: i32 } = null,
    dimensions: ?struct { width: i32, height: i32 } = null,
    dimensions_hint: DimensionsHint = .{},
    decoration_hint: river.WindowV1.DecorationHint = .only_supports_csd,
} = .{},

/// State requested by the window manager client but not yet committed.
uncommitted: WmState = .{},
/// State requested by the window manager client and committed.
committed: WmState = .{},

/// State to be sent to the window in the next configure.
pending: State = .{},
/// State sent to the window in the latest configure.
sent: State = .{},

pub fn create(impl: Impl) error{OutOfMemory}!*Window {
    assert(impl != .none);

    const window = try util.gpa.create(Window);
    errdefer util.gpa.destroy(window);

    const tree = try server.scene.hidden_tree.createSceneTree();
    errdefer tree.node.destroy();

    const popup_tree = try server.scene.hidden_tree.createSceneTree();
    errdefer popup_tree.node.destroy();

    window.* = .{
        .node = undefined,
        .impl = impl,
        .tree = tree,
        .surfaces = try Scene.SaveableSurfaces.init(tree),
        .border = .{
            .left = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
            .right = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
            .top = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
            .bottom = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
        },
        .popup_tree = popup_tree,
        .link = undefined,
    };

    window.node.init(.window);

    server.wm.windows.append(window);

    window.tree.node.setEnabled(false);
    window.popup_tree.node.setEnabled(false);

    try SceneNodeData.attach(&window.tree.node, .{ .window = window });
    try SceneNodeData.attach(&window.popup_tree.node, .{ .window = window });

    return window;
}

/// If saved buffers of the window are currently in use by a transaction,
/// mark this window for destruction when the transaction completes. Otherwise
/// destroy immediately.
pub fn destroy(window: *Window, when: enum { lazy, assert }) void {
    // We can't assert(window.wm_pending.state != .ready) since the client may
    // have exited after making its empty initial commit but before the surface
    // is mapped.
    assert(window.impl == .none);
    assert(!window.mapped);

    // We may need to send the closed event and make the window_v1/node_v1 objects
    // inert here if the client exits after the empty initial commit but before
    // the window is mapped.
    window.makeInert();

    window.destroying = true;

    {
        var it = server.input_manager.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.focused == .window and seat.focused.window == window) {
                seat.focus(.none);
            }
        }
    }

    // If there are still saved buffers, then this window needs to be kept
    // around until the current transaction completes. This function will be
    // called again in WindowManager.commitTransaction()
    if (!window.surfaces.saved.node.enabled) {
        window.tree.node.destroy();
        window.popup_tree.node.destroy();

        window.link.remove();

        window.node.deinit();

        util.gpa.destroy(window);
    } else {
        switch (when) {
            .lazy => {},
            .assert => unreachable,
        }
    }
}

pub fn setDimensionsHint(window: *Window, hint: DimensionsHint) void {
    window.wm_pending.dimensions_hint = hint;
    if (!meta.eql(window.wm_sent.dimensions_hint, hint)) {
        server.wm.dirtyPending();
    }
}

pub fn setDimensions(window: *Window, width: i32, height: i32) void {
    window.wm_pending.box.width = width;
    window.wm_pending.box.height = height;

    switch (window.sent.op) {
        .none, .move => {},
        .resize => |data| {
            assert(data.seat.op != null);

            if (data.edges.left) {
                window.wm_pending.box.x = data.start_box.x + data.start_box.width - width;
            } else if (data.edges.right) {
                window.wm_pending.box.x = data.start_box.x;
            }

            if (data.edges.top) {
                window.wm_pending.box.y = data.start_box.y + data.start_box.height - height;
            } else if (data.edges.bottom) {
                window.wm_pending.box.y = data.start_box.y;
            }
        },
    }

    if (window.wm_sent.dimensions == null or window.wm_sent.position == null or
        width != window.wm_sent.dimensions.?.width or
        height != window.wm_sent.dimensions.?.height or
        window.wm_pending.box.x != window.wm_sent.position.?.x or
        window.wm_pending.box.y != window.wm_sent.position.?.y)
    {
        server.wm.dirtyPending();
    }
}

pub fn setDecorationHint(window: *Window, hint: river.WindowV1.DecorationHint) void {
    window.wm_pending.decoration_hint = hint;
    if (hint != window.wm_sent.decoration_hint) {
        server.wm.dirtyPending();
    }
}

pub fn setFullscreenRequested(window: *Window, fullscreen_requested: bool) void {
    if (fullscreen_requested) {
        window.wm_pending.fullscreen_requested = .fullscreen;
    } else {
        window.wm_pending.fullscreen_requested = .exit;
    }
    server.wm.dirtyPending();
}

/// Send dirty pending state as part of an in progress update sequence.
pub fn sendDirty(window: *Window) void {
    switch (window.wm_pending.state) {
        .init => {},
        .closing => {
            window.wm_pending.state = .init;
            window.initialized = false;
            window.uncommitted = .{};
            window.committed = .{};

            window.node.link_uncommitted.remove();
            window.node.link_uncommitted.init();
            window.node.link_committed.remove();
            window.node.link_committed.init();
            window.node.link_inflight.remove();
            window.node.link_inflight.init();

            window.close();
        },
        .ready => {
            const wm_v1 = server.wm.object orelse return;
            const new = window.object == null;
            const window_v1 = window.object orelse blk: {
                const window_v1 = river.WindowV1.create(wm_v1.getClient(), wm_v1.getVersion(), 0) catch {
                    log.err("out of memory", .{});
                    return; // try again next update
                };
                window.object = window_v1;
                window_v1.setHandler(*Window, handleRequest, handleDestroy, window);
                wm_v1.sendWindow(window_v1);

                server.wm.uncommitted.render_list.append(&window.node);

                break :blk window_v1;
            };
            errdefer comptime unreachable;

            const pending = &window.wm_pending;
            const sent = &window.wm_sent;

            // XXX send all dirty pending state
            if (new or sent.position == null or
                pending.box.x != sent.position.?.x or pending.box.y != sent.position.?.y)
            {
                if (window.node.object) |node_v1| {
                    node_v1.sendPosition(pending.box.x, pending.box.y);
                    sent.position = .{
                        .x = pending.box.x,
                        .y = pending.box.y,
                    };
                }
            }
            if (!pending.box.empty() and (new or sent.dimensions == null or
                pending.box.width != sent.dimensions.?.width or
                pending.box.height != sent.dimensions.?.height))
            {
                window_v1.sendDimensions(window.wm_pending.box.width, window.wm_pending.box.height);
                sent.dimensions = .{
                    .width = pending.box.width,
                    .height = pending.box.height,
                };
            }
            if (new or !meta.eql(pending.dimensions_hint, sent.dimensions_hint)) {
                window_v1.sendDimensionsHint(
                    pending.dimensions_hint.min_width,
                    pending.dimensions_hint.min_height,
                    pending.dimensions_hint.max_width,
                    pending.dimensions_hint.max_height,
                );
                sent.dimensions_hint = pending.dimensions_hint;
            }
            if (new or pending.decoration_hint != sent.decoration_hint) {
                window_v1.sendDecorationHint(window.wm_pending.decoration_hint);
                sent.decoration_hint = pending.decoration_hint;
            }
            switch (pending.fullscreen_requested) {
                .no_request => {},
                .fullscreen => window_v1.sendFullscreenRequested(null),
                .exit => window_v1.sendExitFullscreenRequested(),
            }
            pending.fullscreen_requested = .no_request;

            if (new or pending.dirty_app_id) {
                window_v1.sendAppId(window.getAppId());
                pending.dirty_app_id = false;
            }
            if (new or pending.dirty_title) {
                window_v1.sendTitle(window.getTitle());
                pending.dirty_title = false;
            }
        },
    }
}

pub fn makeInert(window: *Window) void {
    if (window.object) |window_v1| {
        window.object = null;
        window_v1.sendClosed();
        window_v1.setHandler(?*anyopaque, handleRequestInert, null, null);
        window.node.makeInert();
    } else {
        assert(window.node.object == null);
    }
}

fn handleRequestInert(
    window_v1: *river.WindowV1,
    request: river.WindowV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) window_v1.destroy();
}

fn handleDestroy(_: *river.WindowV1, window: *Window) void {
    window.object = null;
    window.node.makeInert();
}

fn handleRequest(
    window_v1: *river.WindowV1,
    request: river.WindowV1.Request,
    window: *Window,
) void {
    assert(window.object == window_v1);
    const uncommitted = &window.uncommitted;
    switch (request) {
        .destroy => {
            // XXX send protocol error
            window_v1.destroy();
        },
        .close => uncommitted.close = true,
        .get_node => |args| {
            if (window.node.object != null) {
                window_v1.postError(.node_exists, "window already has a node object");
                return;
            }
            window.node.createObject(window_v1.getClient(), window_v1.getVersion(), args.id);
        },
        .propose_dimensions => |args| {
            if (args.width < 0 or args.height < 0) {
                // XXX send protocol error
            }
            uncommitted.dimensions = .{
                .width = @intCast(args.width),
                .height = @intCast(args.height),
            };
        },
        .hide => uncommitted.hidden = true,
        .show => uncommitted.hidden = false,
        .use_ssd => uncommitted.ssd = true,
        .use_csd => uncommitted.ssd = false,
        .set_borders => |args| {
            if (args.width < 0) {
                // XXX send protocol error
            }
            uncommitted.border = .{
                .edges = args.edges,
                .width = @intCast(args.width),
                .r = args.r,
                .g = args.g,
                .b = args.b,
                .a = args.a,
            };
        },
        .set_tiled => |args| uncommitted.tiled = args.edges,
        .get_decoration_surface => {}, // XXX support decoration surfaces
        .set_capabilities => |args| uncommitted.capabilities = args.caps,
        .inform_maximized => uncommitted.maximized = true,
        .inform_unmaximized => uncommitted.maximized = false,
        .fullscreen => uncommitted.fullscreen = true,
        .exit_fullscreen => uncommitted.fullscreen = false,
    }
}

pub fn commitWmState(window: *Window) void {
    if (!window.initialized and window.uncommitted.dimensions != null) {
        window.initialized = true;
    }

    window.committed = .{
        .position = window.uncommitted.position orelse window.committed.position,
        .dimensions = window.uncommitted.dimensions orelse window.committed.dimensions,
        .hidden = window.uncommitted.hidden,
        .ssd = window.uncommitted.ssd,
        .border = window.uncommitted.border,
        .tiled = window.uncommitted.tiled,
        .capabilities = window.uncommitted.capabilities,
        .maximized = window.uncommitted.maximized,
        .fullscreen = window.uncommitted.fullscreen,
        .close = window.uncommitted.close,
        .op = window.uncommitted.op,
    };
    window.uncommitted.position = null;
    window.uncommitted.dimensions = null;
    window.uncommitted.op = .none;
}

/// Applies committed state from the window manager client to the inflight state.
/// Returns true if the configure should be waited for by the transaction system.
pub fn configure(window: *Window) bool {
    if (!window.initialized) return false;

    assert(!window.destroying);

    if (window.committed.close) {
        window.close();
    }

    const activated = blk: {
        var it = server.wm.sent.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.committed.focus == .window and seat.committed.focus.window == window) {
                break :blk true;
            }
        }
        break :blk false;
    };

    const committed = &window.committed;

    window.pending = .{
        .width = window.pending.width,
        .height = window.pending.height,
        .hidden = committed.hidden,
        .activated = activated,
        .ssd = committed.ssd,
        .border = committed.border,
        .tiled = committed.tiled,
        .capabilities = committed.capabilities,
        .maximized = committed.maximized,
        .fullscreen = committed.fullscreen,
        .op = window.pending.op,
    };

    // Ensure a position/dimension event is sent if the window manager has
    // modified them even if the actual position/dimensions do not change.
    if (committed.position) |position| {
        if (window.pending.op == .none) {
            window.wm_pending.box.x = position.x;
            window.wm_pending.box.y = position.y;
        }

        window.wm_sent.position = null;
        committed.position = null;
    }
    if (committed.dimensions) |dimensions| {
        if (window.pending.op == .none) {
            window.pending.width = dimensions.width;
            window.pending.height = dimensions.height;
        }

        window.wm_sent.dimensions = null;
        committed.dimensions = null;
    }
    committed.op = .none;

    const track_configure = switch (window.impl) {
        .toplevel => |*toplevel| toplevel.configure(),
        .xwayland => |*xwindow| xwindow.configure(),
        .none => unreachable,
    };

    if (track_configure and window.mapped) {
        window.surfaces.save();
        window.sendFrameDone();
    }

    return track_configure;
}

pub fn commitTransaction(window: *Window) void {
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
                },
                .idle, .committed => {
                    toplevel.configure_state = .idle;
                },
                .timed_out, .timed_out_acked => unreachable,
            }
            window.setDimensions(toplevel.geometry.width, toplevel.geometry.height);
        },
        .xwayland => |xwindow| {
            window.setDimensions(xwindow.xsurface.width, xwindow.xsurface.height);
        },
        .none => {},
    }

    window.updateSceneState();
}

pub fn updateSceneState(window: *Window) void {
    const box = &window.wm_pending.box;
    window.tree.node.setPosition(box.x, box.y);
    window.popup_tree.node.setPosition(box.x, box.y);

    // f32 cannot represent all u32 values exactly, therefore we must initially use f64
    // (which can) and then cast to f32, potentially losing precision.
    const border = &window.sent.border;
    const color: [4]f32 = .{
        @floatCast(@as(f64, @floatFromInt(border.r)) / math.maxInt(u32)),
        @floatCast(@as(f64, @floatFromInt(border.g)) / math.maxInt(u32)),
        @floatCast(@as(f64, @floatFromInt(border.b)) / math.maxInt(u32)),
        @floatCast(@as(f64, @floatFromInt(border.a)) / math.maxInt(u32)),
    };

    var left: wlr.Box = .{
        .x = -@as(i32, border.width),
        .y = 0,
        .width = border.width,
        .height = box.height,
    };
    var right: wlr.Box = .{
        .x = box.width,
        .y = 0,
        .width = border.width,
        .height = box.height,
    };
    const top: wlr.Box = .{
        .x = 0,
        .y = -@as(i32, border.width),
        .width = box.width,
        .height = border.width,
    };
    const bottom: wlr.Box = .{
        .x = 0,
        .y = box.height,
        .width = box.width,
        .height = border.width,
    };

    // Use left and right scene rects to draw the corners if needed
    if (border.edges.top) {
        left.y -= border.width;
        left.height += border.width;
        right.y -= border.width;
        right.height += border.width;
    }
    if (border.edges.bottom) {
        left.height += border.width;
        right.height += border.width;
    }

    inline for (.{
        .{ .name = "left", .box = left },
        .{ .name = "right", .box = right },
        .{ .name = "top", .box = top },
        .{ .name = "bottom", .box = bottom },
    }) |edge| {
        const rect = @field(window.border, edge.name);
        rect.node.setEnabled(@field(border.edges, edge.name));
        rect.node.setPosition(edge.box.x, edge.box.y);
        rect.setSize(edge.box.width, edge.box.height);
        rect.setColor(&color);
    }
}

/// Returns null if the window is currently being destroyed and no longer has
/// an associated surface.
/// May also return null for Xwayland windows that are not currently mapped.
pub fn rootSurface(window: Window) ?*wlr.Surface {
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.base.surface,
        .xwayland => |xwindow| xwindow.xsurface.surface,
        .none => null,
    };
}

pub fn sendFrameDone(window: Window) void {
    assert(window.mapped and !window.destroying);

    var now: posix.timespec = undefined;
    posix.clock_gettime(posix.CLOCK.MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
    window.rootSurface().?.sendFrameDone(&now);
}

pub fn close(window: Window) void {
    switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.sendClose(),
        .xwayland => |xwindow| xwindow.xsurface.close(),
        .none => {},
    }
}

pub fn destroyPopups(window: Window) void {
    switch (window.impl) {
        .toplevel => |toplevel| toplevel.destroyPopups(),
        .xwayland, .none => {},
    }
}

/// Return the current title of the window if any.
pub fn getTitle(window: Window) ?[*:0]const u8 {
    assert(!window.destroying);
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.title,
        .xwayland => |xwindow| xwindow.xsurface.title,
        .none => unreachable,
    };
}

/// Return the current app_id of the window if any.
pub fn getAppId(window: Window) ?[*:0]const u8 {
    assert(!window.destroying);
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.app_id,
        // X11 clients don't have an app_id but the class serves a similar role.
        .xwayland => |xwindow| xwindow.xsurface.class,
        .none => unreachable,
    };
}

/// Called by the impl when the surface is ready to be displayed
pub fn map(window: *Window) !void {
    log.debug("window '{?s}' mapped", .{window.getTitle()});

    assert(!window.mapped and !window.destroying);
    window.mapped = true;
}

/// Called by the impl when the surface will no longer be displayed
pub fn unmap(window: *Window) void {
    log.debug("window '{?s}' unmapped", .{window.getTitle()});

    window.surfaces.save();

    assert(window.mapped and !window.destroying);
    window.mapped = false;

    assert(window.wm_pending.state != .closing);
    window.wm_pending.state = .closing;
    server.wm.dirtyPending();
}

pub fn notifyTitle(window: *Window) void {
    window.wm_pending.dirty_title = true;
    server.wm.dirtyPending();
}

pub fn notifyAppId(window: *Window) void {
    window.wm_pending.dirty_app_id = true;
    server.wm.dirtyPending();
}
