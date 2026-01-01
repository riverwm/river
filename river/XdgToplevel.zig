// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const XdgToplevel = @This();

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const XdgPopup = @import("XdgPopup.zig");
const Window = @import("Window.zig");
const XdgDecoration = @import("XdgDecoration.zig");

const log = std.log.scoped(.xdg);

/// TODO(zig): get rid of this and use @fieldParentPtr(), https://github.com/ziglang/zig/issues/6611
window: *Window,

wlr_toplevel: *wlr.XdgToplevel,

decoration: ?XdgDecoration = null,

geometry: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

configure_state: union(enum) {
    /// No configure has been sent since the last configure was acked.
    idle,
    /// A configure was sent with the given serial but has not yet been acked.
    inflight: u32,
    /// A configure was acked but the surface has not yet been committed.
    acked,
    /// A configure was acked and the surface was committed.
    committed,
    /// A configure was sent but not acked before the transaction timed out.
    timed_out: u32,
    /// A configure was sent and acked but not committed before the transaction timed out.
    timed_out_acked,
} = .idle,

// Listeners that are always active over the window's lifetime
destroy: wl.Listener(void) = .init(handleDestroy),
ack_configure: wl.Listener(*wlr.XdgSurface.Configure) = .init(handleAckConfigure),
map: wl.Listener(void) = .init(handleMap),
unmap: wl.Listener(void) = .init(handleUnmap),
commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
new_popup: wl.Listener(*wlr.XdgPopup) = .init(handleNewPopup),
request_show_window_menu: wl.Listener(*wlr.XdgToplevel.event.ShowWindowMenu) = .init(handleRequestShowWindowMenu),
request_fullscreen: wl.Listener(void) = .init(handleRequestFullscreen),
request_maximize: wl.Listener(void) = .init(handleRequestMaximize),
request_minimize: wl.Listener(void) = .init(handleRequestMinimize),
request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(handleRequestMove),
request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(handleRequestResize),
set_parent: wl.Listener(void) = .init(handleSetParent),
set_title: wl.Listener(void) = .init(handleSetTitle),
set_app_id: wl.Listener(void) = .init(handleSetAppId),

pub fn create(wlr_toplevel: *wlr.XdgToplevel) error{OutOfMemory}!void {
    log.debug("new xdg_toplevel", .{});

    const window = try Window.create(.{ .toplevel = .{
        .window = undefined,
        .wlr_toplevel = wlr_toplevel,
    } });
    errdefer window.destroy();

    const toplevel = &window.impl.toplevel;

    // This listener must be added before the scene xdg surface is created.
    // Otherwise, the scene surface nodes will already be disabled by the unmap
    // listeners in the scene xdg surface and scene subsurface tree helpers
    // before our unmap listener is called.
    // However, we need the surface tree to be unchanged in our unmap listener
    // so that we can save the buffers for frame perfection.
    // TODO(wlroots) This is fragile, it would be good if wlroots gave us a
    // better alternative here.
    wlr_toplevel.base.surface.events.unmap.add(&toplevel.unmap);
    errdefer toplevel.unmap.link.remove();

    _ = try window.surfaces.tree.createSceneXdgSurface(wlr_toplevel.base);

    toplevel.window = window;

    wlr_toplevel.base.data = toplevel;
    wlr_toplevel.base.surface.data = &window.tree.node;

    wlr_toplevel.events.destroy.add(&toplevel.destroy);
    wlr_toplevel.base.events.ack_configure.add(&toplevel.ack_configure);
    wlr_toplevel.base.surface.events.map.add(&toplevel.map);
    wlr_toplevel.base.surface.events.commit.add(&toplevel.commit);
    wlr_toplevel.base.events.new_popup.add(&toplevel.new_popup);
    wlr_toplevel.events.request_show_window_menu.add(&toplevel.request_show_window_menu);
    wlr_toplevel.events.request_fullscreen.add(&toplevel.request_fullscreen);
    wlr_toplevel.events.request_maximize.add(&toplevel.request_maximize);
    wlr_toplevel.events.request_minimize.add(&toplevel.request_minimize);
    wlr_toplevel.events.request_move.add(&toplevel.request_move);
    wlr_toplevel.events.request_resize.add(&toplevel.request_resize);
    wlr_toplevel.events.set_parent.add(&toplevel.set_parent);
    wlr_toplevel.events.set_title.add(&toplevel.set_title);
    wlr_toplevel.events.set_app_id.add(&toplevel.set_app_id);
}

/// Send a configure event, return true if the configure should be tracked
/// and current surfaces saved for frame perfection.
pub fn configure(toplevel: *XdgToplevel) bool {
    switch (toplevel.configure_state) {
        .idle, .timed_out, .timed_out_acked => {},
        .inflight, .acked, .committed => unreachable,
    }

    defer switch (toplevel.configure_state) {
        .idle, .inflight, .acked => {},
        .timed_out, .timed_out_acked, .committed => unreachable,
    };

    const scheduled = &toplevel.window.configure_scheduled;

    if (!toplevel.needsConfigure()) {
        // If no new configure is required, continue to track a timed out configure
        // from the previous transaction if any.
        switch (toplevel.configure_state) {
            .idle => return false,
            .timed_out => |serial| {
                toplevel.configure_state = .{ .inflight = serial };
                return true;
            },
            .timed_out_acked => {
                toplevel.configure_state = .acked;
                return true;
            },
            .inflight, .acked, .committed => unreachable,
        }
    }

    const wlr_toplevel = toplevel.wlr_toplevel;

    _ = wlr_toplevel.setActivated(scheduled.activated);
    _ = wlr_toplevel.setTiled(.{
        .top = scheduled.tiled.top,
        .bottom = scheduled.tiled.bottom,
        .left = scheduled.tiled.left,
        .right = scheduled.tiled.right,
    });
    _ = wlr_toplevel.setWmCapabilities(.{
        .window_menu = scheduled.capabilities.window_menu,
        .maximize = scheduled.capabilities.maximize,
        .fullscreen = scheduled.capabilities.fullscreen,
        .minimize = scheduled.capabilities.minimize,
    });
    _ = wlr_toplevel.setMaximized(scheduled.maximized);
    _ = wlr_toplevel.setFullscreen(scheduled.inform_fullscreen);
    _ = wlr_toplevel.setResizing(scheduled.resizing);
    if (toplevel.decoration) |decoration| {
        _ = decoration.wlr_decoration.setMode(if (scheduled.ssd) .server_side else .client_side);
    }

    const width: u31 = scheduled.width orelse switch (toplevel.configure_state) {
        .idle => @intCast(toplevel.geometry.width),
        .timed_out, .timed_out_acked => toplevel.window.configure_sent.width.?,
        .inflight, .acked, .committed => unreachable,
    };
    const height: u31 = scheduled.height orelse switch (toplevel.configure_state) {
        .idle => @intCast(toplevel.geometry.height),
        .timed_out, .timed_out_acked => toplevel.window.configure_sent.height.?,
        .inflight, .acked, .committed => unreachable,
    };
    const configure_serial = wlr_toplevel.setSize(width, height);

    toplevel.window.configure_sent = toplevel.window.configure_scheduled;
    toplevel.window.configure_sent.width = width;
    toplevel.window.configure_sent.height = height;
    toplevel.window.configure_scheduled.width = null;
    toplevel.window.configure_scheduled.height = null;

    // Generally, only track configures (and save surfaces) if there is a
    // change in size involved. If the configure state is not idle, we are
    // currently tracking a timed out configure and should instead track the
    // new one even if there is no change in size involved.
    if (width == toplevel.geometry.width and height == toplevel.geometry.height and
        toplevel.configure_state == .idle)
    {
        return false;
    }

    toplevel.configure_state = .{
        .inflight = configure_serial,
    };

    return true;
}

fn needsConfigure(toplevel: *XdgToplevel) bool {
    const scheduled = &toplevel.window.configure_scheduled;
    const sent = &toplevel.window.configure_sent;

    if (scheduled.width != null and scheduled.width != sent.width) return true;
    if (scheduled.height != null and scheduled.height != sent.height) return true;
    if (scheduled.activated != sent.activated) return true;
    if (scheduled.ssd != sent.ssd) return true;
    if (!std.meta.eql(scheduled.tiled, sent.tiled)) return true;
    if (!std.meta.eql(scheduled.capabilities, sent.capabilities)) return true;
    if (scheduled.maximized != sent.maximized) return true;
    if (scheduled.inform_fullscreen != sent.inform_fullscreen) return true;
    if ((scheduled.resizing) != (sent.resizing)) return true;

    return false;
}

pub fn destroyPopups(toplevel: XdgToplevel) void {
    var it = toplevel.wlr_toplevel.base.popups.safeIterator(.forward);
    while (it.next()) |wlr_xdg_popup| wlr_xdg_popup.destroy();
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("destroy", listener);

    // This can be be non-null here if the client commits a protocol error or
    // if it exits without destroying its wayland objects.
    if (toplevel.decoration) |*decoration| {
        decoration.deinit();
    }
    assert(toplevel.decoration == null);

    toplevel.destroy.link.remove();
    toplevel.ack_configure.link.remove();
    toplevel.map.link.remove();
    toplevel.unmap.link.remove();
    toplevel.commit.link.remove();
    toplevel.new_popup.link.remove();
    toplevel.request_show_window_menu.link.remove();
    toplevel.request_fullscreen.link.remove();
    toplevel.request_maximize.link.remove();
    toplevel.request_minimize.link.remove();
    toplevel.request_move.link.remove();
    toplevel.request_resize.link.remove();
    toplevel.set_parent.link.remove();
    toplevel.set_title.link.remove();
    toplevel.set_app_id.link.remove();

    // The wlr_surface may outlive the wlr_xdg_toplevel so we must clean up the user data.
    toplevel.wlr_toplevel.base.surface.data = null;

    const window = toplevel.window;
    window.impl = .destroying;
    switch (window.state) {
        .init, .closing => {},
        // This can happen if the xdg toplevel is destroyed after the initial
        // commit but before the window is mapped.
        .ready, .initialized => {
            window.state = .closing;
            server.wm.dirtyWindowing();
        },
        // State must have been set to closing in Window.unmap()
        .mapped => unreachable,
    }
}

fn handleMap(listener: *wl.Listener(void)) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("map", listener);

    toplevel.window.map() catch {
        log.err("out of memory", .{});
        toplevel.wlr_toplevel.resource.getClient().postNoMemory();
    };
}

/// Called when the surface is unmapped and will no longer be displayed.
fn handleUnmap(listener: *wl.Listener(void)) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("unmap", listener);

    toplevel.window.unmap();
}

fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("new_popup", listener);

    XdgPopup.create(wlr_xdg_popup, toplevel.window.popup_tree, toplevel.window.popup_tree) catch {
        wlr_xdg_popup.resource.postNoMemory();
        return;
    };
}

fn handleAckConfigure(
    listener: *wl.Listener(*wlr.XdgSurface.Configure),
    acked_configure: *wlr.XdgSurface.Configure,
) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("ack_configure", listener);
    switch (toplevel.configure_state) {
        .inflight => |serial| if (acked_configure.serial == serial) {
            toplevel.configure_state = .acked;
        },
        .timed_out => |serial| if (acked_configure.serial == serial) {
            toplevel.configure_state = .timed_out_acked;
        },
        .acked, .idle, .committed, .timed_out_acked => {},
    }
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("commit", listener);
    const window = toplevel.window;

    window.setDimensionsHint(.{
        .min_width = @intCast(toplevel.wlr_toplevel.current.min_width),
        .min_height = @intCast(toplevel.wlr_toplevel.current.min_height),
        .max_width = @intCast(toplevel.wlr_toplevel.current.max_width),
        .max_height = @intCast(toplevel.wlr_toplevel.current.max_height),
    });

    if (toplevel.wlr_toplevel.base.initial_commit) {
        assert(window.state != .ready);
        window.state = .ready;
        server.wm.dirtyWindowing();
        return;
    }

    if (window.state != .mapped) {
        return;
    }

    switch (toplevel.configure_state) {
        .idle, .committed, .timed_out => {
            const old_geometry = toplevel.geometry;
            toplevel.geometry = toplevel.wlr_toplevel.base.geometry;

            const size_changed = toplevel.geometry.width != old_geometry.width or
                toplevel.geometry.height != old_geometry.height;

            if (size_changed) {
                log.debug(
                    "client initiated size change: {}x{} -> {}x{}",
                    .{ old_geometry.width, old_geometry.height, toplevel.geometry.width, toplevel.geometry.height },
                );

                window.setDimensions(@intCast(toplevel.geometry.width), @intCast(toplevel.geometry.height));
            } else if (old_geometry.x != toplevel.geometry.x or
                old_geometry.y != toplevel.geometry.y)
            {
                // We need to update the surface clip box to reflect the geometry change.
                window.renderFinish();
            }
        },
        // If the client has not yet acked our configure, we need to send a
        // frame done event so that it commits another buffer. These
        // buffers won't be rendered since we are still rendering our
        // stashed buffer from when the transaction started.
        .inflight => window.sendFrameDone(),
        .acked, .timed_out_acked => {
            toplevel.geometry = toplevel.wlr_toplevel.base.geometry;

            window.rendering_scheduled.width = @intCast(toplevel.geometry.width);
            window.rendering_scheduled.height = @intCast(toplevel.geometry.height);

            switch (toplevel.configure_state) {
                .acked => {
                    toplevel.configure_state = .committed;
                    server.wm.notifyConfigured();
                },
                .timed_out_acked => {
                    toplevel.configure_state = .idle;
                    server.wm.dirtyRendering();
                },
                else => unreachable,
            }
        },
    }
}

fn handleRequestShowWindowMenu(
    listener: *wl.Listener(*wlr.XdgToplevel.event.ShowWindowMenu),
    event: *wlr.XdgToplevel.event.ShowWindowMenu,
) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("request_show_window_menu", listener);
    toplevel.window.wm_scheduled.show_window_menu_requested = .{
        .x = event.x - toplevel.geometry.x,
        .y = event.y - toplevel.geometry.y,
    };
    server.wm.dirtyWindowing();
}

fn handleRequestFullscreen(listener: *wl.Listener(void)) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("request_fullscreen", listener);
    if (toplevel.wlr_toplevel.requested.fullscreen) {
        if (toplevel.wlr_toplevel.requested.fullscreen_output) |wlr_output| {
            const output: *Output = @ptrCast(@alignCast(wlr_output.data));
            toplevel.window.wm_scheduled.fullscreen_requested = .{ .fullscreen = output };
        } else {
            toplevel.window.wm_scheduled.fullscreen_requested = .{ .fullscreen = null };
        }
    } else {
        toplevel.window.wm_scheduled.fullscreen_requested = .exit;
    }
    server.wm.dirtyWindowing();
}

fn handleRequestMaximize(listener: *wl.Listener(void)) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("request_maximize", listener);
    if (toplevel.wlr_toplevel.requested.maximized) {
        toplevel.window.wm_scheduled.maximize_requested = .maximize;
    } else {
        toplevel.window.wm_scheduled.maximize_requested = .unmaximize;
    }
    server.wm.dirtyWindowing();
}

fn handleRequestMinimize(listener: *wl.Listener(void)) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("request_minimize", listener);
    toplevel.window.wm_scheduled.minimize_requested = true;
    server.wm.dirtyWindowing();
}

fn handleRequestMove(
    listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
    event: *wlr.XdgToplevel.event.Move,
) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("request_move", listener);
    const seat: *Seat = @ptrCast(@alignCast(event.seat.seat.data));

    // Moving windows with touch or tablet tool is not yet supported.
    if (seat.wlr_seat.validatePointerGrabSerial(null, event.serial)) {
        toplevel.window.wm_scheduled.pointer_move_requested = seat;
        server.wm.dirtyWindowing();
    }
}

fn handleRequestResize(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("request_resize", listener);
    const seat: *Seat = @ptrCast(@alignCast(event.seat.seat.data));

    // Resizing windows with touch or tablet tool is not yet supported.
    if (seat.wlr_seat.validatePointerGrabSerial(null, event.serial)) {
        toplevel.window.wm_scheduled.pointer_resize_requested = .{
            .seat = seat,
            .edges = @bitCast(event.edges),
        };
        server.wm.dirtyWindowing();
    }
}

fn handleSetParent(_: *wl.Listener(void)) void {
    server.wm.dirtyWindowing();
}

/// Called when the client sets / updates its title
fn handleSetTitle(listener: *wl.Listener(void)) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("set_title", listener);
    toplevel.window.notifyTitle();
}

/// Called when the client sets / updates its app_id
fn handleSetAppId(listener: *wl.Listener(void)) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("set_app_id", listener);
    toplevel.window.notifyAppId();
}
