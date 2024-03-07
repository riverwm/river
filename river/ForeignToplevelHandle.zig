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

const View = @import("View.zig");
const Seat = @import("Seat.zig");

wlr_handle: ?*wlr.ForeignToplevelHandleV1 = null,

foreign_activate: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated) =
    wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated).init(handleForeignActivate),
foreign_fullscreen: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen) =
    wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen).init(handleForeignFullscreen),
foreign_close: wl.Listener(*wlr.ForeignToplevelHandleV1) =
    wl.Listener(*wlr.ForeignToplevelHandleV1).init(handleForeignClose),

pub fn map(handle: *ForeignToplevelHandle) void {
    const view: *View = @fieldParentPtr("foreign_toplevel_handle", handle);

    assert(handle.wlr_handle == null);

    handle.wlr_handle = wlr.ForeignToplevelHandleV1.create(server.foreign_toplevel_manager) catch {
        std.log.err("out of memory", .{});
        return;
    };

    handle.wlr_handle.?.events.request_activate.add(&handle.foreign_activate);
    handle.wlr_handle.?.events.request_fullscreen.add(&handle.foreign_fullscreen);
    handle.wlr_handle.?.events.request_close.add(&handle.foreign_close);

    if (view.getTitle()) |title| handle.wlr_handle.?.setTitle(title);
    if (view.getAppId()) |app_id| handle.wlr_handle.?.setAppId(app_id);
}

pub fn unmap(handle: *ForeignToplevelHandle) void {
    const wlr_handle = handle.wlr_handle orelse return;

    handle.foreign_activate.link.remove();
    handle.foreign_fullscreen.link.remove();
    handle.foreign_close.link.remove();

    wlr_handle.destroy();

    handle.wlr_handle = null;
}

/// Must be called just before the view's inflight state is made current.
pub fn update(handle: *ForeignToplevelHandle) void {
    const view: *View = @fieldParentPtr("foreign_toplevel_handle", handle);

    const wlr_handle = handle.wlr_handle orelse return;

    if (view.inflight.output != view.current.output) {
        if (view.current.output) |output| wlr_handle.outputLeave(output.wlr_output);
        if (view.inflight.output) |output| wlr_handle.outputEnter(output.wlr_output);
    }

    wlr_handle.setActivated(view.inflight.focus != 0);
    wlr_handle.setFullscreen(view.inflight.output != null and
        view.inflight.output.?.inflight.fullscreen == view);
}

/// Only honors the request if the view is already visible on the seat's
/// currently focused output.
fn handleForeignActivate(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated),
    event: *wlr.ForeignToplevelHandleV1.event.Activated,
) void {
    const handle: *ForeignToplevelHandle = @fieldParentPtr("foreign_activate", listener);
    const view: *View = @fieldParentPtr("foreign_toplevel_handle", handle);
    const seat: *Seat = @ptrFromInt(event.seat.data);

    seat.focus(view);
    server.root.applyPending();
}

fn handleForeignFullscreen(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen),
    event: *wlr.ForeignToplevelHandleV1.event.Fullscreen,
) void {
    const handle: *ForeignToplevelHandle = @fieldParentPtr("foreign_fullscreen", listener);
    const view: *View = @fieldParentPtr("foreign_toplevel_handle", handle);

    view.pending.fullscreen = event.fullscreen;
    server.root.applyPending();
}

fn handleForeignClose(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1),
    _: *wlr.ForeignToplevelHandleV1,
) void {
    const handle: *ForeignToplevelHandle = @fieldParentPtr("foreign_close", listener);
    const view: *View = @fieldParentPtr("foreign_toplevel_handle", handle);

    view.close();
}
