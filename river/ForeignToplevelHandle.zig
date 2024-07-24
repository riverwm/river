// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2023 The River Developers
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

const ForeignToplevelHandle = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;

const Window = @import("Window.zig");
const Seat = @import("Seat.zig");

wlr_handle: ?*wlr.ForeignToplevelHandleV1 = null,

foreign_activate: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated) =
    wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated).init(handleForeignActivate),
foreign_fullscreen: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen) =
    wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen).init(handleForeignFullscreen),
foreign_close: wl.Listener(*wlr.ForeignToplevelHandleV1) =
    wl.Listener(*wlr.ForeignToplevelHandleV1).init(handleForeignClose),

pub fn map(handle: *ForeignToplevelHandle) void {
    const window: *Window = @fieldParentPtr("foreign_toplevel_handle", handle);

    assert(handle.wlr_handle == null);

    handle.wlr_handle = wlr.ForeignToplevelHandleV1.create(server.foreign_toplevel_manager) catch {
        std.log.err("out of memory", .{});
        return;
    };

    handle.wlr_handle.?.events.request_activate.add(&handle.foreign_activate);
    handle.wlr_handle.?.events.request_fullscreen.add(&handle.foreign_fullscreen);
    handle.wlr_handle.?.events.request_close.add(&handle.foreign_close);

    if (window.getTitle()) |title| handle.wlr_handle.?.setTitle(title);
    if (window.getAppId()) |app_id| handle.wlr_handle.?.setAppId(app_id);
}

pub fn unmap(handle: *ForeignToplevelHandle) void {
    const wlr_handle = handle.wlr_handle orelse return;

    handle.foreign_activate.link.remove();
    handle.foreign_fullscreen.link.remove();
    handle.foreign_close.link.remove();

    wlr_handle.destroy();

    handle.wlr_handle = null;
}

/// Must be called just before the window's inflight state is made current.
pub fn update(handle: *ForeignToplevelHandle) void {
    const window: *Window = @fieldParentPtr("foreign_toplevel_handle", handle);

    const wlr_handle = handle.wlr_handle orelse return;

    wlr_handle.setActivated(window.inflight.focus != 0);
    wlr_handle.setFullscreen(window.inflight.fullscreen);
}

/// Only honors the request if the window is already visible on the seat's
/// currently focused output.
fn handleForeignActivate(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated),
    event: *wlr.ForeignToplevelHandleV1.event.Activated,
) void {
    const handle: *ForeignToplevelHandle = @fieldParentPtr("foreign_activate", listener);
    const window: *Window = @fieldParentPtr("foreign_toplevel_handle", handle);
    const seat: *Seat = @ptrFromInt(event.seat.data);

    seat.focus(window);
    server.wm.dirtyPending();
}

fn handleForeignFullscreen(
    _: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen),
    _: *wlr.ForeignToplevelHandleV1.event.Fullscreen,
) void {
    //const handle: *ForeignToplevelHandle = @fieldParentPtr("foreign_fullscreen", listener);
    //const window: *Window = @fieldParentPtr("foreign_toplevel_handle", handle);

    // XXX Can I just delete this protocol?
}

fn handleForeignClose(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1),
    _: *wlr.ForeignToplevelHandleV1,
) void {
    const handle: *ForeignToplevelHandle = @fieldParentPtr("foreign_close", listener);
    const window: *Window = @fieldParentPtr("foreign_toplevel_handle", handle);

    window.close();
}
