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

/// Initialized on map
geometry: wlr.Box = undefined,

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
destroy: wl.Listener(void) = wl.Listener(void).init(handleDestroy),
ack_configure: wl.Listener(*wlr.XdgSurface.Configure) =
    wl.Listener(*wlr.XdgSurface.Configure).init(handleAckConfigure),
map: wl.Listener(void) = wl.Listener(void).init(handleMap),
unmap: wl.Listener(void) = wl.Listener(void).init(handleUnmap),
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),
new_popup: wl.Listener(*wlr.XdgPopup) = wl.Listener(*wlr.XdgPopup).init(handleNewPopup),
request_fullscreen: wl.Listener(void) = wl.Listener(void).init(handleRequestFullscreen),
request_move: wl.Listener(*wlr.XdgToplevel.event.Move) =
    wl.Listener(*wlr.XdgToplevel.event.Move).init(handleRequestMove),
request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) =
    wl.Listener(*wlr.XdgToplevel.event.Resize).init(handleRequestResize),
set_title: wl.Listener(void) = wl.Listener(void).init(handleSetTitle),
set_app_id: wl.Listener(void) = wl.Listener(void).init(handleSetAppId),

pub fn create(wlr_toplevel: *wlr.XdgToplevel) error{OutOfMemory}!void {
    log.debug("new xdg_toplevel", .{});

    const window = try Window.create(.{ .toplevel = .{
        .window = undefined,
        .wlr_toplevel = wlr_toplevel,
    } });
    errdefer window.destroy(.assert);

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

    _ = try window.surface_tree.createSceneXdgSurface(wlr_toplevel.base);

    toplevel.window = window;

    wlr_toplevel.base.data = @intFromPtr(toplevel);
    wlr_toplevel.base.surface.data = @intFromPtr(&window.tree.node);

    wlr_toplevel.events.destroy.add(&toplevel.destroy);
    wlr_toplevel.base.events.ack_configure.add(&toplevel.ack_configure);
    wlr_toplevel.base.surface.events.map.add(&toplevel.map);
    wlr_toplevel.base.surface.events.commit.add(&toplevel.commit);
    wlr_toplevel.base.events.new_popup.add(&toplevel.new_popup);
    wlr_toplevel.events.request_fullscreen.add(&toplevel.request_fullscreen);
    wlr_toplevel.events.request_move.add(&toplevel.request_move);
    wlr_toplevel.events.request_resize.add(&toplevel.request_resize);
    wlr_toplevel.events.set_title.add(&toplevel.set_title);
    wlr_toplevel.events.set_app_id.add(&toplevel.set_app_id);
}

/// Send a configure event, applying the inflight state of the window.
/// If force is true, a configure will always be sent but not necessarily tracked.
pub fn configure(toplevel: *XdgToplevel, force: bool) bool {
    switch (toplevel.configure_state) {
        .idle, .timed_out, .timed_out_acked => {},
        .inflight, .acked, .committed => unreachable,
    }

    defer switch (toplevel.configure_state) {
        .idle, .inflight, .acked => {},
        .timed_out, .timed_out_acked, .committed => unreachable,
    };

    const inflight = &toplevel.window.inflight;
    const current = &toplevel.window.current;

    if (!force and !toplevel.needsConfigure()) {
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

    _ = wlr_toplevel.setActivated(inflight.activated);
    _ = wlr_toplevel.setTiled(.{
        .top = inflight.tiled.top,
        .bottom = inflight.tiled.bottom,
        .left = inflight.tiled.left,
        .right = inflight.tiled.right,
    });
    _ = wlr_toplevel.setWmCapabilities(.{
        .window_menu = inflight.capabilities.window_menu,
        .maximize = inflight.capabilities.maximize,
        .fullscreen = inflight.capabilities.fullscreen,
        .minimize = inflight.capabilities.minimize,
    });
    _ = wlr_toplevel.setMaximized(inflight.maximized);
    _ = wlr_toplevel.setFullscreen(inflight.fullscreen);
    _ = wlr_toplevel.setResizing(inflight.op == .resize);

    if (toplevel.decoration) |decoration| {
        _ = decoration.wlr_decoration.setMode(if (inflight.ssd) .server_side else .client_side);
    }

    // We need to call this wlroots function even if the inflight dimensions
    // match the current dimensions in order to prevent wlroots internal state
    // from getting out of sync in the case where a client has resized the toplevel.
    const configure_serial = wlr_toplevel.setSize(inflight.box.width, inflight.box.height);

    // Only track configures with the transaction system if they affect the dimensions of the window.
    // If the configure state is not idle this means we are currently tracking a timed out
    // configure from a previous transaction and should instead track the newly sent configure.
    if (inflight.box.width != 0 and inflight.box.width == current.box.width and
        inflight.box.height != 0 and inflight.box.height == current.box.height and
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
    const inflight = &toplevel.window.inflight;
    const current = &toplevel.window.current;

    // Never send configures to hidden windows.
    // If transitioning from hidden to not-hidden, send a configure.
    if (inflight.hidden) return false;
    if (current.hidden) return true;

    if (inflight.box.width == 0 or inflight.box.width != current.box.width or
        inflight.box.height == 0 or inflight.box.height != current.box.height)
    {
        return true;
    }

    if (inflight.activated != current.activated) return true;
    if (inflight.ssd != current.ssd) return true;
    if (!std.meta.eql(inflight.tiled, current.tiled)) return true;
    if (!std.meta.eql(inflight.capabilities, current.capabilities)) return true;
    if (inflight.maximized != current.maximized) return true;
    if (inflight.fullscreen != current.fullscreen) return true;
    if ((inflight.op == .resize) != (current.op == .resize)) return true;

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
    toplevel.request_fullscreen.link.remove();
    toplevel.request_move.link.remove();
    toplevel.request_resize.link.remove();
    toplevel.set_title.link.remove();
    toplevel.set_app_id.link.remove();

    // The wlr_surface may outlive the wlr_xdg_toplevel so we must clean up the user data.
    toplevel.wlr_toplevel.base.surface.data = 0;

    const window = toplevel.window;
    window.impl = .none;
    window.destroy(.lazy);
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
        assert(window.pending.state != .ready);
        window.pending.state = .ready;
        server.wm.dirtyPending();
        return;
    }

    if (!window.mapped) {
        return;
    }

    switch (toplevel.configure_state) {
        .idle, .committed, .timed_out => {
            const old_geometry = toplevel.geometry;
            toplevel.wlr_toplevel.base.getGeometry(&toplevel.geometry);

            const size_changed = toplevel.geometry.width != old_geometry.width or
                toplevel.geometry.height != old_geometry.height;

            if (size_changed) {
                log.debug(
                    "client initiated size change: {}x{} -> {}x{}",
                    .{ old_geometry.width, old_geometry.height, toplevel.geometry.width, toplevel.geometry.height },
                );
                // TODO check tiled state
                if (!window.current.fullscreen) {
                    // It seems that a disappointingly high number of clients have a buggy
                    // response to configure events. They ack the configure immediately but then
                    // proceed to make one or more wl_surface.commit requests with the old size
                    // before updating the size of the surface. This obviously makes river's
                    // efforts towards frame perfection futile for such clients. However, in the
                    // interest of best serving river's users we will fix up their size here after
                    // logging a shame message.
                    log.err("client with app-id '{s}' is buggy and initiated size change while tiled or fullscreen, shame on it", .{
                        window.getAppId() orelse "",
                    });
                }

                window.setDimensions(toplevel.geometry.width, toplevel.geometry.height);
                window.current = window.inflight;
                window.updateSceneState();
            } else if (old_geometry.x != toplevel.geometry.x or
                old_geometry.y != toplevel.geometry.y)
            {
                // We need to update the surface clip box to reflect the geometry change.
                window.updateSceneState();
            }
        },
        // If the client has not yet acked our configure, we need to send a
        // frame done event so that it commits another buffer. These
        // buffers won't be rendered since we are still rendering our
        // stashed buffer from when the transaction started.
        .inflight => window.sendFrameDone(),
        .acked, .timed_out_acked => {
            toplevel.wlr_toplevel.base.getGeometry(&toplevel.geometry);

            if (false and window.inflight.resizing) {
                window.resizeUpdatePosition(toplevel.geometry.width, toplevel.geometry.height);
            }

            window.setDimensions(toplevel.geometry.width, toplevel.geometry.height);

            switch (toplevel.configure_state) {
                .acked => {
                    toplevel.configure_state = .committed;
                    server.wm.notifyConfigured();
                },
                .timed_out_acked => {
                    toplevel.configure_state = .idle;
                    window.current = window.inflight;
                    window.updateSceneState();
                },
                else => unreachable,
            }
        },
    }
}

fn handleRequestFullscreen(listener: *wl.Listener(void)) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("request_fullscreen", listener);
    toplevel.window.setFullscreenRequested(toplevel.wlr_toplevel.requested.fullscreen);
}

fn handleRequestMove(
    listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
    event: *wlr.XdgToplevel.event.Move,
) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("request_move", listener);
    _ = toplevel;
    const seat: *Seat = @ptrFromInt(event.seat.seat.data);

    // Moving windows with touch or tablet tool is not yet supported.
    if (seat.wlr_seat.validatePointerGrabSerial(null, event.serial)) {
        // XXX queue pointer_move_requested, dirtyPending()
    }
}

fn handleRequestResize(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
    const toplevel: *XdgToplevel = @fieldParentPtr("request_resize", listener);
    _ = toplevel;
    const seat: *Seat = @ptrFromInt(event.seat.seat.data);

    // Resizing windows with touch or tablet tool is not yet supported.
    if (seat.wlr_seat.validatePointerGrabSerial(null, event.serial)) {
        // XXX queue pointer_resize_requested, dirtyPending()
    }
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
