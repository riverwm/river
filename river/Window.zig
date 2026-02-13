// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

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
const SlotMap = @import("slotmap").SlotMap;

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
    destroying,
};

pub const FullscreenRequest = union(enum) {
    no_request,
    fullscreen: ?*Output,
    exit,
};

pub const Border = struct {
    edges: river.WindowV1.Edges = .{},
    width: u31 = 0,
    r: u32 = 0,
    b: u32 = 0,
    g: u32 = 0,
    a: u32 = 0,
};

/// Windowing state requested by the wm.
const WmRequested = struct {
    dimensions: ?struct { width: u31, height: u31 },
    ssd: bool,
    tiled: river.WindowV1.Edges,
    capabilities: river.WindowV1.Capabilities,
    resizing: bool,
    maximized: bool,
    fullscreen: ?*Output,
    inform_fullscreen: bool,
    close: bool,

    pub const init: WmRequested = .{
        .dimensions = null,
        .ssd = false,
        .tiled = .{},
        .capabilities = .{
            .window_menu = true,
            .maximize = true,
            .fullscreen = true,
            .minimize = true,
        },
        .resizing = false,
        .maximized = false,
        .fullscreen = null,
        .inform_fullscreen = false,
        .close = false,
    };
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
    inform_fullscreen: bool = false,
    resizing: bool = false,
};

/// Rendering state requested by the wm.
const RenderingRequested = struct {
    x: i32,
    y: i32,
    hidden: bool,
    border: Border,
    clip: wlr.Box,
    content_clip: wlr.Box,

    pub const init: RenderingRequested = .{
        .x = 0,
        .y = 0,
        .hidden = false,
        .border = .{},
        .clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .content_clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };
};

pub const Ref = packed struct {
    key: SlotMap(*Window).Key,

    pub fn get(ref: Ref) ?*Window {
        return server.wm.windows.get(ref.key);
    }
};

ref: Ref,

/// The window management protocol object for this window
/// Created in manageStart() when state is .ready
/// Set to null in manageStart() when state is .closing
object: ?*river.WindowV1 = null,
node: WmNode,

state: enum {
    /// Initial state, also returned to after closed event is sent.
    init,
    /// The window is ready to be configured.
    /// The river_window_v1 will be created in the next manage sequence.
    ready,
    /// The first configure has been sent but the window is not yet mapped.
    initialized,
    /// The window is mapped.
    mapped,
    /// The closed event will be sent in the next manage sequence.
    closing,
} = .init,

/// The implementation of this window
impl: Impl,

/// This is the root scene tree for the window.
/// The trees in the following fields are in rendering order.
tree: *wlr.SceneTree,

/// Opaque black rectangle used as the background while this window is rendered fullscreen.
/// TODO consider using one of these per output rather than one per window to save memory
/// if the complexity tradeoff is worth it.
fullscreen_background: *wlr.SceneRect,

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

/// State to be sent to the wm in the next manage sequence.
wm_scheduled: struct {
    dimensions_hint: DimensionsHint = .{},
    decoration_hint: river.WindowV1.DecorationHint = .only_supports_csd,
    show_window_menu_requested: ?struct { x: i32, y: i32 } = null,
    /// Set back to no_request at the end of each update sequence
    fullscreen_requested: FullscreenRequest = .no_request,
    maximize_requested: enum {
        no_request,
        maximize,
        unmaximize,
    } = .no_request,
    minimize_requested: bool = false,
    dirty_app_id: bool = false,
    dirty_title: bool = false,
    pointer_move_requested: ?*Seat = null,
    pointer_resize_requested: ?struct {
        seat: *Seat,
        edges: river.WindowV1.Edges,
    } = null,
} = .{},

/// State sent to the wm in the latest manage sequence.
/// This state is only kept around in order to avoid sending redundant events
/// to the wm.
wm_sent: struct {
    dimensions_hint: DimensionsHint = .{},
    decoration_hint: river.WindowV1.DecorationHint = .only_supports_csd,
    parent: ?Window.Ref = null,
} = .{},

/// Windowing state requested by the wm.
wm_requested: WmRequested = .init,

/// State to be sent to the window in the next configure.
configure_scheduled: Configure = .{},
/// State sent to the window in the latest configure.
configure_sent: Configure = .{},

/// State to be sent to the wm in the next render sequence.
rendering_scheduled: struct {
    /// Dimensions committed by the window.
    width: u31 = 0,
    height: u31 = 0,
    /// Send dimensions even if they are unchanged.
    resend_dimensions: bool = false,
} = .{},

/// State sent to the wm in the latest render sequence.
rendering_sent: struct {
    width: u31 = 0,
    height: u31 = 0,
} = .{},

/// Rendering state requested by the wm.
rendering_requested: RenderingRequested = .init,

/// The currently rendered position/dimensions of the window in the scene graph
box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

foreign_toplevel_handle: ?*wlr.ExtForeignToplevelHandleV1 = null,

pub fn create(impl: Impl) error{OutOfMemory}!*Window {
    assert(impl != .destroying);

    const window = try util.gpa.create(Window);
    errdefer util.gpa.destroy(window);

    const key = try server.wm.windows.put(util.gpa, window);
    errdefer server.wm.windows.remove(key);

    const tree = try server.scene.hidden_tree.createSceneTree();
    errdefer tree.node.destroy();

    const popup_tree = try server.scene.hidden_tree.createSceneTree();
    errdefer popup_tree.node.destroy();

    window.* = .{
        .ref = .{ .key = key },
        .node = undefined,
        .impl = impl,
        .tree = tree,
        .fullscreen_background = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 1 }),
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
    };

    window.node.init(.window);

    window.decorations_below.init();
    window.decorations_above.init();

    window.tree.node.setEnabled(false);
    window.popup_tree.node.setEnabled(false);
    window.fullscreen_background.node.setEnabled(false);

    try SceneNodeData.attach(&window.tree.node, .{ .window = window });
    try SceneNodeData.attach(&window.popup_tree.node, .{ .window = window });

    return window;
}

/// It's safe to destroy the window after we no longer need the saved buffers
/// for frame perfection. We no longer need the saved buffers after the manage
/// sequence in which the closed event was sent is completed and the following
/// render sequence is completed as well.
pub fn destroy(window: *Window) void {
    assert(window.impl == .destroying);

    switch (window.state) {
        .init => {},
        .closing => {
            server.wm.dirtyWindowing();
            return;
        },
        .ready, .initialized, .mapped => unreachable,
    }
    assert(window.object == null);

    {
        var it = server.input_manager.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.focused == .window and seat.focused.window == window) {
                seat.focus(.none);
            }
        }
    }

    inline for (.{ &window.decorations_above, &window.decorations_below }) |decorations| {
        var it = decorations.safeIterator(.forward);
        while (it.next()) |decoration| decoration.destroy();
    }

    window.tree.node.destroy();
    window.popup_tree.node.destroy();

    window.node.deinit();

    server.wm.windows.remove(window.ref.key);

    util.gpa.destroy(window);
}

pub fn setDimensionsHint(window: *Window, hint: DimensionsHint) void {
    window.wm_scheduled.dimensions_hint = hint;
    if (!meta.eql(window.wm_sent.dimensions_hint, hint)) {
        server.wm.dirtyWindowing();
    }
}

pub fn setDimensions(window: *Window, width: u31, height: u31) void {
    window.rendering_scheduled.width = width;
    window.rendering_scheduled.height = height;

    if (window.rendering_scheduled.resend_dimensions or
        window.rendering_scheduled.width != window.rendering_sent.width or
        window.rendering_scheduled.height != window.rendering_sent.height)
    {
        server.wm.dirtyRendering();
    }
}

pub fn setDecorationHint(window: *Window, hint: river.WindowV1.DecorationHint) void {
    window.wm_scheduled.decoration_hint = hint;
    if (hint != window.wm_sent.decoration_hint) {
        server.wm.dirtyWindowing();
    }
}

/// Send dirty state as part of a manage sequence.
pub fn manageStart(window: *Window) void {
    switch (window.state) {
        .init => {},
        .closing => {
            window.state = .init;
            window.wm_sent = .{};
            window.wm_requested = .init;
            window.rendering_sent = .{};
            window.rendering_requested = .init;

            window.node.link.remove();
            window.node.link.init();

            window.makeInert();
        },
        .ready, .initialized, .mapped => {
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

                window.node.link.remove();
                server.wm.rendering_requested.list.append(&window.node);

                break :blk window_v1;
            };
            errdefer comptime unreachable;

            if (new) {
                if (window_v1.getVersion() >= 2) {
                    window_v1.sendUnreliablePid(window.unreliablePid());
                }
            }

            const scheduled = &window.wm_scheduled;
            const sent = &window.wm_sent;

            if (new or !meta.eql(scheduled.dimensions_hint, sent.dimensions_hint)) {
                window_v1.sendDimensionsHint(
                    scheduled.dimensions_hint.min_width,
                    scheduled.dimensions_hint.min_height,
                    scheduled.dimensions_hint.max_width,
                    scheduled.dimensions_hint.max_height,
                );
                sent.dimensions_hint = scheduled.dimensions_hint;
            }
            if (new or scheduled.decoration_hint != sent.decoration_hint) {
                window_v1.sendDecorationHint(window.wm_scheduled.decoration_hint);
                sent.decoration_hint = scheduled.decoration_hint;
            }

            if (scheduled.show_window_menu_requested) |offset| {
                window_v1.sendShowWindowMenuRequested(offset.x, offset.y);
                scheduled.show_window_menu_requested = null;
            }
            switch (scheduled.fullscreen_requested) {
                .no_request => {},
                .fullscreen => |output_hint| {
                    if (output_hint) |output| {
                        window_v1.sendFullscreenRequested(output.object);
                    } else {
                        window_v1.sendFullscreenRequested(null);
                    }
                },
                .exit => window_v1.sendExitFullscreenRequested(),
            }
            scheduled.fullscreen_requested = .no_request;
            switch (scheduled.maximize_requested) {
                .no_request => {},
                .maximize => window_v1.sendMaximizeRequested(),
                .unmaximize => window_v1.sendUnmaximizeRequested(),
            }
            scheduled.maximize_requested = .no_request;
            if (scheduled.minimize_requested) {
                window_v1.sendMinimizeRequested();
            }
            scheduled.minimize_requested = false;

            if (window.getParent()) |parent| {
                if (sent.parent == null or sent.parent.?.get() != parent) {
                    window_v1.sendParent(parent.object);
                    sent.parent = parent.ref;
                }
            } else if (sent.parent != null) {
                window_v1.sendParent(null);
                sent.parent = null;
            }

            if (new or scheduled.dirty_app_id) {
                window_v1.sendAppId(window.getAppId());
                scheduled.dirty_app_id = false;
            }
            if (new or scheduled.dirty_title) {
                window_v1.sendTitle(window.getTitle());
                scheduled.dirty_title = false;
            }

            if (scheduled.pointer_move_requested) |seat| {
                if (seat.object) |seat_v1| {
                    log.debug("send pointer move requested", .{});
                    window_v1.sendPointerMoveRequested(seat_v1);
                }
            }
            scheduled.pointer_move_requested = null;
            if (scheduled.pointer_resize_requested) |data| {
                if (data.seat.object) |seat_v1| {
                    log.debug("send pointer resize requested", .{});
                    window_v1.sendPointerResizeRequested(seat_v1, data.edges);
                }
            }
            scheduled.pointer_resize_requested = null;
        },
    }
}

fn makeInert(window: *Window) void {
    if (window.object) |window_v1| {
        window_v1.sendClosed();
        window_v1.setHandler(?*anyopaque, handleRequestInert, null, null);
        handleDestroy(window_v1, window);
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
    window.wm_requested = .init;
    window.rendering_requested = .{
        .x = window.rendering_requested.x,
        .y = window.rendering_requested.y,
        .hidden = false,
        .border = .{},
        .clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .content_clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };
    server.wm.dirtyWindowing();
    window.node.makeInert();
    inline for (.{ &window.decorations_above, &window.decorations_below }) |decorations| {
        var it = decorations.iterator(.forward);
        while (it.next()) |decoration| decoration.makeInert();
    }
}

fn handleRequest(
    window_v1: *river.WindowV1,
    request: river.WindowV1.Request,
    window: *Window,
) void {
    assert(window.object == window_v1);
    const wm_requested = &window.wm_requested;
    const rendering_requested = &window.rendering_requested;
    switch (request) {
        .destroy => window_v1.destroy(),
        .close => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.close = true;
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
                window_v1.postError(.invalid_dimensions, "dimensions must be greater than or equal to 0 ");
                return;
            }
            wm_requested.dimensions = .{
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
            wm_requested.ssd = true;
        },
        .use_csd => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.ssd = false;
        },
        .set_borders => |args| {
            if (!server.wm.ensureRendering()) return;
            if (args.width < 0) {
                window_v1.postError(.invalid_border, "border width must be greater than or equal to 0 ");
                return;
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
            wm_requested.tiled = args.edges;
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
        .inform_resize_start => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.resizing = true;
        },
        .inform_resize_end => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.resizing = false;
        },
        .set_capabilities => |args| {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.capabilities = args.caps;
        },
        .inform_maximized => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.maximized = true;
        },
        .inform_unmaximized => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.maximized = false;
        },
        .inform_fullscreen => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.inform_fullscreen = true;
        },
        .inform_not_fullscreen => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.inform_fullscreen = false;
        },
        .fullscreen => |args| {
            if (!server.wm.ensureWindowing()) return;
            const data = args.output.getUserData() orelse return;
            const output: *Output = @ptrCast(@alignCast(data));
            wm_requested.fullscreen = output;
        },
        .exit_fullscreen => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.fullscreen = null;
        },
        .set_clip_box => |args| {
            if (!server.wm.ensureRendering()) return;
            if (args.width < 0 or args.height < 0) {
                window_v1.postError(.invalid_clip_box, "width/height must be greater than or equal to 0 ");
                return;
            }
            rendering_requested.clip = .{
                .x = args.x,
                .y = args.y,
                .width = args.width,
                .height = args.height,
            };
        },
        .set_content_clip_box => |args| {
            if (!server.wm.ensureRendering()) return;
            if (args.width < 0 or args.height < 0) {
                window_v1.postError(.invalid_clip_box, "width/height must be greater than or equal to 0 ");
                return;
            }
            rendering_requested.content_clip = .{
                .x = args.x,
                .y = args.y,
                .width = args.width,
                .height = args.height,
            };
        },
    }
}

/// Applies window management state from the window manager and sends a configure
/// to the window if necessary.
/// Returns true if the configure should be waited for by the transaction system.
pub fn manageFinish(window: *Window) bool {
    const wm_requested = &window.wm_requested;

    // This can happen if the window is destroyed after being sent to the wm but
    // before being mapped.
    if (window.impl == .destroying) {
        assert(window.state == .closing);
        return false;
    }

    switch (window.state) {
        .init => unreachable,
        .ready => {
            if (wm_requested.dimensions == null and wm_requested.fullscreen == null) {
                return false;
            }
            window.state = .initialized;
        },
        .initialized, .mapped => {},
        .closing => return false,
    }

    window.configure_scheduled.ssd = wm_requested.ssd;
    window.configure_scheduled.tiled = wm_requested.tiled;
    window.configure_scheduled.capabilities = wm_requested.capabilities;
    window.configure_scheduled.resizing = wm_requested.resizing;
    window.configure_scheduled.maximized = wm_requested.maximized;
    window.configure_scheduled.inform_fullscreen = wm_requested.inform_fullscreen;

    if (wm_requested.close) {
        window.close();
        wm_requested.close = false;
    }

    {
        window.configure_scheduled.activated = false;
        var it = server.wm.sent.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.focused == .window and seat.focused.window == window) {
                window.configure_scheduled.activated = true;
                break;
            }
        }
    }

    if (wm_requested.fullscreen) |output| {
        const width, const height = output.sent.dimensions();
        if (window.configure_sent.width != width or
            window.configure_sent.height != height)
        {
            window.configure_scheduled.width = width;
            window.configure_scheduled.height = height;
            window.rendering_scheduled.resend_dimensions = true;
        }
    } else if (wm_requested.dimensions) |dimensions| {
        window.configure_scheduled.width = dimensions.width;
        window.configure_scheduled.height = dimensions.height;
        window.rendering_scheduled.resend_dimensions = true;
    }
    wm_requested.dimensions = null;

    const track_configure = switch (window.impl) {
        .toplevel => |*toplevel| toplevel.configure(),
        .xwayland => |*xwindow| xwindow.configure(),
        .destroying => unreachable,
    };

    if (track_configure and window.state == .mapped) {
        window.surfaces.save();
        window.sendFrameDone();
    }

    return track_configure;
}

pub fn renderStart(window: *Window) void {
    switch (window.impl) {
        .toplevel => |*toplevel| {
            switch (toplevel.configure_state) {
                .inflight, .acked => {
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
                    switch (toplevel.configure_state) {
                        .inflight => |serial| toplevel.configure_state = .{ .timed_out = serial },
                        .acked => toplevel.configure_state = .timed_out_acked,
                        else => unreachable,
                    }
                },
                .committed => {
                    toplevel.configure_state = .idle;
                },
                // A timed_out or timed_out_acked value is possible in the case of a
                // manage sequence followed by two render sequences for example.
                .idle, .timed_out, .timed_out_acked => {},
            }
            window.rendering_scheduled.width = @intCast(toplevel.geometry.width);
            window.rendering_scheduled.height = @intCast(toplevel.geometry.height);
        },
        .xwayland => |xwindow| {
            window.rendering_scheduled.width = xwindow.xsurface.width;
            window.rendering_scheduled.height = xwindow.xsurface.height;
        },
        .destroying => {},
    }

    const sent = &window.rendering_sent;
    const scheduled = &window.rendering_scheduled;

    // The check for 0 width/height is necessary to handle timeout of the first configure sent.
    if (scheduled.width != 0 and scheduled.height != 0 and
        (scheduled.resend_dimensions or
            scheduled.width != sent.width or scheduled.height != sent.height))
    {
        if (window.object) |window_v1| {
            window_v1.sendDimensions(scheduled.width, scheduled.height);
            window.rendering_scheduled.resend_dimensions = false;
        }
    }
    sent.width = scheduled.width;
    sent.height = scheduled.height;
}

pub fn renderFinish(window: *Window) void {
    const requested = &window.rendering_requested;
    window.tree.node.setEnabled(!requested.hidden);
    window.popup_tree.node.setEnabled(!requested.hidden);

    window.box.width = window.rendering_sent.width;
    window.box.height = window.rendering_sent.height;

    var clip: wlr.Box = requested.clip;
    var content_clip: wlr.Box = requested.content_clip;
    if (window.wm_requested.fullscreen) |output| {
        window.box.x = output.sent.x;
        window.box.y = output.sent.y;
        window.fullscreen_background.node.setEnabled(true);
        const width, const height = output.sent.dimensions();
        window.fullscreen_background.setSize(width, height);
        clip = .{ .x = 0, .y = 0, .width = width, .height = height };
        content_clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        inline for (.{ "left", "right", "top", "bottom" }) |edge| {
            @field(window.border, edge).node.setEnabled(false);
        }
    } else {
        window.box.x = requested.x;
        window.box.y = requested.y;
        window.fullscreen_background.node.setEnabled(false);
        window.drawBorders();
    }
    window.tree.node.setPosition(window.box.x, window.box.y);
    window.popup_tree.node.setPosition(window.box.x, window.box.y);

    switch (window.impl) {
        .xwayland => |*xwindow| _ = xwindow.configure(),
        .toplevel, .destroying => {},
    }

    window.applySurfaceClip(&clip, &content_clip);
    inline for (.{ &window.decorations_above, &window.decorations_below }) |decorations| {
        var it = decorations.iterator(.forward);
        while (it.next()) |decoration| {
            decoration.renderFinish(&clip);
        }
    }
}

fn drawBorders(window: *Window) void {
    const requested = &window.rendering_requested;
    var content: wlr.Box = .{
        .x = 0,
        .y = 0,
        .width = window.box.width,
        .height = window.box.height,
    };
    if (requested.content_clip.empty() or
        content.intersection(&content, &requested.content_clip))
    {
        // f32 cannot represent all u32 values exactly, therefore we must initially use f64
        // (which can) and then cast to f32, potentially losing precision.
        const border = &requested.border;
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
            .height = content.height,
        };
        var right: wlr.Box = .{
            .x = content.width,
            .y = 0,
            .width = border.width,
            .height = content.height,
        };
        var top: wlr.Box = .{
            .x = 0,
            .y = -@as(i32, border.width),
            .width = content.width,
            .height = border.width,
        };
        var bottom: wlr.Box = .{
            .x = 0,
            .y = content.height,
            .width = content.width,
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
            .{ .name = "left", .box = &left },
            .{ .name = "right", .box = &right },
            .{ .name = "top", .box = &top },
            .{ .name = "bottom", .box = &bottom },
        }) |edge| {
            if (!requested.clip.empty()) {
                if (!edge.box.intersection(edge.box, &requested.clip)) {
                    // TODO(wlroots): remove this redundant code after fixed upstream
                    // https://gitlab.freedesktop.org/wlroots/wlroots/-/merge_requests/5084
                    edge.box.* = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
                }
            }
            const rect = @field(window.border, edge.name);
            rect.node.setEnabled(@field(border.edges, edge.name));
            rect.node.setPosition(edge.box.x, edge.box.y);
            rect.setSize(edge.box.width, edge.box.height);
            rect.setColor(&color);
        }
    }
}

fn applySurfaceClip(window: *Window, a: *const wlr.Box, b: *const wlr.Box) void {
    var surface_clip: wlr.Box = undefined;
    if (!a.empty() and !b.empty()) {
        if (!surface_clip.intersection(a, b)) {
            // Clip boxes are both non-empty but don't intersect, all window
            // content is clipped away.
            window.surfaces.setEnabled(false);
            return;
        }
    } else if (!a.empty()) {
        surface_clip = a.*;
    } else {
        surface_clip = b.*;
    }
    window.surfaces.setEnabled(true);
    switch (window.impl) {
        .toplevel => |toplevel| {
            surface_clip.x += toplevel.geometry.x;
            surface_clip.y += toplevel.geometry.y;
        },
        .xwayland, .destroying => {},
    }
    // wlroots asserts that a subsurface tree is present.
    if (!window.surfaces.tree.children.empty()) {
        window.surfaces.tree.node.subsurfaceTreeSetClip(&surface_clip);
    }
}

/// Returns null if the window is currently being destroyed and no longer has
/// an associated surface.
/// May also return null for Xwayland windows that are not currently mapped.
pub fn rootSurface(window: Window) ?*wlr.Surface {
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.base.surface,
        .xwayland => |xwindow| xwindow.xsurface.surface,
        .destroying => null,
    };
}

pub fn sendFrameDone(window: Window) void {
    assert(window.state == .mapped);
    assert(window.impl != .destroying);

    var now = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch @panic("CLOCK_MONOTONIC not supported");
    window.rootSurface().?.sendFrameDone(&now);
}

pub fn close(window: Window) void {
    switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.sendClose(),
        .xwayland => |xwindow| xwindow.xsurface.close(),
        .destroying => {},
    }
}

pub fn destroyPopups(window: Window) void {
    switch (window.impl) {
        .toplevel => |toplevel| toplevel.destroyPopups(),
        .xwayland, .destroying => {},
    }
}

pub fn getParent(window: *Window) ?*Window {
    switch (window.impl) {
        .toplevel => |toplevel| {
            const wlr_parent = toplevel.wlr_toplevel.parent orelse return null;
            const parent: *XdgToplevel = @ptrCast(@alignCast(wlr_parent.base.data));
            return parent.window;
        },
        .xwayland => |xwindow| {
            const parent_xsurface = xwindow.xsurface.parent orelse return null;
            const parent_xwindow: *XwaylandWindow = @ptrCast(@alignCast(parent_xsurface.data));
            return parent_xwindow.window;
        },
        .destroying => return null,
    }
}

pub fn unreliablePid(window: *Window) i32 {
    switch (window.impl) {
        .toplevel => |toplevel| {
            const client = toplevel.wlr_toplevel.base.surface.resource.getClient();
            return client.getCredentials().pid;
        },
        .xwayland => |xwindow| return xwindow.xsurface.pid,
        .destroying => unreachable,
    }
}

/// Return the current title of the window if any.
pub fn getTitle(window: Window) ?[*:0]const u8 {
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.title,
        .xwayland => |xwindow| xwindow.xsurface.title,
        .destroying => unreachable,
    };
}

/// Return the current app_id of the window if any.
pub fn getAppId(window: Window) ?[*:0]const u8 {
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.app_id,
        // X11 clients don't have an app_id but the class serves a similar role.
        .xwayland => |xwindow| xwindow.xsurface.class,
        .destroying => unreachable,
    };
}

/// Called by the impl when the surface is ready to be displayed
pub fn map(window: *Window) !void {
    log.debug("window '{?s}' mapped", .{window.getTitle()});
    assert(window.impl != .destroying);
    assert(window.state == .initialized);
    window.state = .mapped;

    if (wlr.ExtForeignToplevelHandleV1.create(server.foreign_toplevel_list, &.{
        .title = window.getTitle(),
        .app_id = window.getAppId(),
    })) |handle| {
        window.foreign_toplevel_handle = handle;
    } else |_| {
        log.err("failed to create ext foreign toplevel handle", .{});
    }
}

/// Called by the impl when the surface will no longer be displayed
pub fn unmap(window: *Window) void {
    log.debug("window '{?s}' unmapped", .{window.getTitle()});

    window.surfaces.save();

    assert(window.impl != .destroying);
    assert(window.state == .mapped);
    window.state = .closing;

    server.wm.dirtyWindowing();

    if (window.foreign_toplevel_handle) |handle| {
        handle.destroy();
        window.foreign_toplevel_handle = null;
    }
}

pub fn notifyTitle(window: *Window) void {
    window.wm_scheduled.dirty_title = true;
    server.wm.dirtyWindowing();

    if (window.foreign_toplevel_handle) |handle| {
        handle.updateState(&.{
            .title = window.getTitle(),
            .app_id = window.getAppId(),
        });
    }
}

pub fn notifyAppId(window: *Window) void {
    window.wm_scheduled.dirty_app_id = true;
    server.wm.dirtyWindowing();

    if (window.foreign_toplevel_handle) |handle| {
        handle.updateState(&.{
            .title = window.getTitle(),
            .app_id = window.getAppId(),
        });
    }
}
