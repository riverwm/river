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

const Decoration = @import("Decoration.zig");
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

pub const Configure = struct {
    width: ?u31 = null,
    height: ?u31 = null,
    /// True if the window has keyboard focus from at least one seat.
    activated: bool = false,
    ssd: bool = false,
    border: Border = .{},
    tiled: river.WindowV1.Edges = .{},
    capabilities: river.WindowV1.Capabilities = .{},
    maximized: bool = false,
    fullscreen: bool = false,
    resizing: bool = false,
};

/// The window management protocol object for this window
/// Created after the window is ready to be configured.
/// Lifetime is managed through windowing_scheduled.state
object: ?*river.WindowV1 = null,
node: WmNode,

/// The implementation of this window
impl: Impl,

/// This is the root scene tree for the window.
/// The trees in the following fields are in rendering order.
tree: *wlr.SceneTree,

decorations_below: wl.list.Head(Decoration, .link),
decorations_below_tree: *wlr.SceneTree,

surfaces: Scene.SaveableSurfaces,

border: struct {
    left: *wlr.SceneRect,
    right: *wlr.SceneRect,
    top: *wlr.SceneRect,
    bottom: *wlr.SceneRect,
},

decorations_above: wl.list.Head(Decoration, .link),
decorations_above_tree: *wlr.SceneTree,

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

/// State to be sent to the wm in the next windowing update sequence.
windowing_scheduled: struct {
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

/// State sent to the wm in the latest windowing update sequence.
/// This state is only kept around in order to avoid sending redundant events
/// to the wm.
windowing_sent: struct {
    dimensions_hint: DimensionsHint = .{},
    decoration_hint: river.WindowV1.DecorationHint = .only_supports_csd,
} = .{},

/// Windowing state requested by the wm.
windowing_requested: struct {
    dimensions: ?struct {
        width: u31,
        height: u31,
    } = null,
    ssd: bool = false,
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
} = .{},

/// State to be sent to the window in the next configure.
configure_scheduled: Configure = .{},
/// State sent to the window in the latest configure.
configure_sent: Configure = .{},

/// State to be sent to the wm in the next rendering update sequence.
rendering_scheduled: struct {
    /// Dimensions committed by the window.
    width: u31 = 0,
    height: u31 = 0,
    /// Send dimensions even if they are unchanged.
    resend_dimensions: bool = false,
} = .{},

/// State sent to the wm in the latest rendering update sequence.
rendering_sent: struct {
    box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
} = .{},

/// Rendering state requested by the wm.
rendering_requested: struct {
    position: ?struct {
        x: i32,
        y: i32,
    } = null,
    hidden: bool = false,
    border: Border = .{},
} = .{},

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
        .decorations_below = undefined,
        .decorations_below_tree = try tree.createSceneTree(),
        .surfaces = try Scene.SaveableSurfaces.init(tree),
        .border = .{
            .left = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
            .right = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
            .top = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
            .bottom = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
        },
        .decorations_above = undefined,
        .decorations_above_tree = try tree.createSceneTree(),
        .popup_tree = popup_tree,
        .link = undefined,
    };

    window.node.init(.window);

    window.decorations_below.init();
    window.decorations_above.init();

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
    assert(window.impl == .none);
    assert(!window.mapped);

    window.destroying = true;

    // We can't assert(window.windowing_scheduled.state != .ready) since the client may
    // have exited after making its empty initial commit but before the surface
    // is mapped.
    switch (window.windowing_scheduled.state) {
        .init => {},
        .closing, .ready => {
            window.windowing_scheduled.state = .closing;
            server.wm.dirtyWindowing();
            return;
        },
    }

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
    window.windowing_scheduled.dimensions_hint = hint;
    if (!meta.eql(window.windowing_sent.dimensions_hint, hint)) {
        server.wm.dirtyWindowing();
    }
}

pub fn setDimensions(window: *Window, width: u31, height: u31) void {
    window.rendering_scheduled.width = width;
    window.rendering_scheduled.height = height;

    if (window.rendering_scheduled.resend_dimensions or
        window.rendering_scheduled.width != window.rendering_sent.box.width or
        window.rendering_scheduled.height != window.rendering_sent.box.height)
    {
        server.wm.dirtyRendering();
    }
}

pub fn setDecorationHint(window: *Window, hint: river.WindowV1.DecorationHint) void {
    window.windowing_scheduled.decoration_hint = hint;
    if (hint != window.windowing_sent.decoration_hint) {
        server.wm.dirtyWindowing();
    }
}

pub fn setFullscreenRequested(window: *Window, fullscreen_requested: bool) void {
    if (fullscreen_requested) {
        window.windowing_scheduled.fullscreen_requested = .fullscreen;
    } else {
        window.windowing_scheduled.fullscreen_requested = .exit;
    }
    server.wm.dirtyWindowing();
}

/// Send dirty windowing state as part of a windowing update sequence.
pub fn updateWindowingStart(window: *Window) void {
    switch (window.windowing_scheduled.state) {
        .init => {},
        .closing => {
            window.initialized = false;
            window.windowing_scheduled.state = .init;
            window.windowing_sent = .{};
            window.windowing_requested = .{};
            window.rendering_sent = .{};
            window.rendering_requested = .{};

            window.node.link.remove();
            window.node.link.init();

            window.makeInert();
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

                server.wm.rendering_requested.list.append(&window.node);

                break :blk window_v1;
            };
            errdefer comptime unreachable;

            const pending = &window.windowing_scheduled;
            const sent = &window.windowing_sent;

            // XXX send all dirty pending state
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
                window_v1.sendDecorationHint(window.windowing_scheduled.decoration_hint);
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

fn makeInert(window: *Window) void {
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
    const windowing_requested = &window.windowing_requested;
    const rendering_requested = &window.rendering_requested;
    switch (request) {
        .destroy => {
            // XXX send protocol error
            window_v1.destroy();
        },
        .close => {
            if (!server.wm.ensureWindowing()) return;
            windowing_requested.close = true;
        },
        .get_node => |args| {
            if (window.node.object != null) {
                window_v1.postError(.node_exists, "window already has a node object");
                return;
            }
            window.node.createObject(window_v1.getClient(), window_v1.getVersion(), args.id);
        },
        .propose_dimensions => |args| {
            if (!server.wm.ensureWindowing()) return;
            if (args.width < 0 or args.height < 0) {
                // XXX send protocol error
            }
            windowing_requested.dimensions = .{
                .width = @intCast(args.width),
                .height = @intCast(args.height),
            };
        },
        .hide => {
            if (!server.wm.ensureRendering()) return;
            rendering_requested.hidden = true;
        },
        .show => {
            if (!server.wm.ensureRendering()) return;
            rendering_requested.hidden = false;
        },
        .use_ssd => {
            if (!server.wm.ensureWindowing()) return;
            windowing_requested.ssd = true;
        },
        .use_csd => {
            if (!server.wm.ensureWindowing()) return;
            windowing_requested.ssd = false;
        },
        .set_borders => |args| {
            if (!server.wm.ensureRendering()) return;
            if (args.width < 0) {
                // XXX send protocol error
            }
            rendering_requested.border = .{
                .edges = args.edges,
                .width = @intCast(args.width),
                .r = args.r,
                .g = args.g,
                .b = args.b,
                .a = args.a,
            };
        },
        .set_tiled => |args| {
            if (!server.wm.ensureWindowing()) return;
            windowing_requested.tiled = args.edges;
        },
        inline .get_decoration_above, .get_decoration_below => |args, req| {
            const above = req == .get_decoration_above;
            const surface = wlr.Surface.fromWlSurface(args.surface);
            const decoration = Decoration.create(
                window_v1.getClient(),
                window_v1.getVersion(),
                args.id,
                surface,
                if (above) window.decorations_above_tree else window.decorations_below_tree,
            ) catch |err| switch (err) {
                error.OutOfMemory, error.ResourceCreateFailed => {
                    window_v1.getClient().postNoMemory();
                    log.err("out of memory", .{});
                    return;
                },
                error.AlreadyHasRole => return,
            };
            if (above) {
                window.decorations_above.append(decoration);
            } else {
                window.decorations_below.append(decoration);
            }
        },
        .set_capabilities => |args| {
            if (!server.wm.ensureWindowing()) return;
            windowing_requested.capabilities = args.caps;
        },
        .inform_maximized => {
            if (!server.wm.ensureWindowing()) return;
            windowing_requested.maximized = true;
        },
        .inform_unmaximized => {
            if (!server.wm.ensureWindowing()) return;
            windowing_requested.maximized = false;
        },
        .fullscreen => {
            if (!server.wm.ensureWindowing()) return;
            windowing_requested.fullscreen = true;
        },
        .exit_fullscreen => {
            if (!server.wm.ensureWindowing()) return;
            windowing_requested.fullscreen = false;
        },
    }
}

/// Applies windowing state from the window manager client  and sends a configure
/// to the window if necessary.
/// Returns true if the configure should be waited for by the transaction system.
pub fn updateWindowingFinish(window: *Window) bool {
    const windowing_requested = &window.windowing_requested;

    if (!window.initialized) {
        if (windowing_requested.dimensions != null) {
            window.initialized = true;
        } else {
            return false;
        }
    }

    assert(!window.destroying);

    window.configure_scheduled.ssd = windowing_requested.ssd;
    window.configure_scheduled.tiled = windowing_requested.tiled;
    window.configure_scheduled.capabilities = windowing_requested.capabilities;
    window.configure_scheduled.maximized = windowing_requested.maximized;
    window.configure_scheduled.fullscreen = windowing_requested.fullscreen;

    if (windowing_requested.close) {
        window.close();
    }

    {
        window.configure_scheduled.activated = false;
        var it = server.wm.windowing_sent.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.windowing_requested.focus == .window and
                seat.windowing_requested.focus.window == window)
            {
                window.configure_scheduled.activated = true;
                break;
            }
        }
    }

    if (windowing_requested.dimensions) |dimensions| {
        if (window.op == .none) {
            window.configure_scheduled.width = dimensions.width;
            window.configure_scheduled.height = dimensions.height;
        }
        windowing_requested.dimensions = null;
        window.rendering_scheduled.resend_dimensions = true;
    }

    windowing_requested.op = .none;

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

pub fn updateRenderingStart(window: *Window) void {
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
            window.rendering_scheduled.width = @intCast(toplevel.geometry.width);
            window.rendering_scheduled.height = @intCast(toplevel.geometry.height);
        },
        .xwayland => |xwindow| {
            window.rendering_scheduled.width = xwindow.xsurface.width;
            window.rendering_scheduled.height = xwindow.xsurface.height;
        },
        .none => {},
    }

    const sent = &window.rendering_sent;
    var scheduled_box: wlr.Box = .{
        .x = sent.box.x,
        .y = sent.box.y,
        .width = window.rendering_scheduled.width,
        .height = window.rendering_scheduled.height,
    };

    switch (window.op) {
        .none => {},
        .move => |data| {
            const seat_op = &data.seat.op.?;
            const dx = seat_op.x - seat_op.start_x;
            const dy = seat_op.y - seat_op.start_y;
            scheduled_box.x = data.start_x + dx;
            scheduled_box.y = data.start_y + dy;
        },
        .resize => |data| {
            assert(data.seat.op != null);
            if (data.edges.left) {
                scheduled_box.x = data.start_box.x + data.start_box.width - scheduled_box.width;
            } else if (data.edges.right) {
                scheduled_box.x = data.start_box.x;
            }
            if (data.edges.top) {
                scheduled_box.y = data.start_box.y + data.start_box.height - scheduled_box.height;
            } else if (data.edges.bottom) {
                scheduled_box.y = data.start_box.y;
            }
        },
    }

    if (scheduled_box.x != sent.box.x or scheduled_box.y != sent.box.y) {
        if (window.node.object) |node_v1| {
            node_v1.sendPosition(scheduled_box.x, scheduled_box.y);
        }
    }
    if (window.rendering_scheduled.resend_dimensions or
        scheduled_box.width != sent.box.width or scheduled_box.height != sent.box.height)
    {
        if (window.object) |window_v1| {
            window_v1.sendDimensions(scheduled_box.width, scheduled_box.height);
            window.rendering_scheduled.resend_dimensions = false;
        }
    }
    sent.box = scheduled_box;
}

pub fn updateRenderingFinish(window: *Window) void {
    window.tree.node.setEnabled(!window.rendering_requested.hidden);
    window.popup_tree.node.setEnabled(!window.rendering_requested.hidden);

    const box = &window.rendering_sent.box;

    if (window.rendering_requested.position) |position| {
        if (window.op == .none) {
            box.x = position.x;
            box.y = position.y;
        }
        window.rendering_requested.position = null;
    }

    window.tree.node.setPosition(box.x, box.y);
    window.popup_tree.node.setPosition(box.x, box.y);

    // f32 cannot represent all u32 values exactly, therefore we must initially use f64
    // (which can) and then cast to f32, potentially losing precision.
    const border = &window.rendering_requested.border;
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

    inline for (.{ &window.decorations_above, &window.decorations_below }) |decorations| {
        var it = decorations.iterator(.forward);
        while (it.next()) |decoration| decoration.updateRenderingFinish();
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

    assert(window.windowing_scheduled.state != .closing);
    window.windowing_scheduled.state = .closing;
    server.wm.dirtyWindowing();
}

pub fn notifyTitle(window: *Window) void {
    window.windowing_scheduled.dirty_title = true;
    server.wm.dirtyWindowing();
}

pub fn notifyAppId(window: *Window) void {
    window.windowing_scheduled.dirty_app_id = true;
    server.wm.dirtyWindowing();
}
