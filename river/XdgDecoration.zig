// SPDX-FileCopyrightText: © 2023 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const XdgDecoration = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const XdgToplevel = @import("XdgToplevel.zig");

wlr_decoration: *wlr.XdgToplevelDecorationV1,

destroy: wl.Listener(*wlr.XdgToplevelDecorationV1) = wl.Listener(*wlr.XdgToplevelDecorationV1).init(handleDestroy),
request_mode: wl.Listener(*wlr.XdgToplevelDecorationV1) = wl.Listener(*wlr.XdgToplevelDecorationV1).init(handleRequestMode),

pub fn init(wlr_decoration: *wlr.XdgToplevelDecorationV1) void {
    const toplevel: *XdgToplevel = @ptrCast(@alignCast(wlr_decoration.toplevel.base.data));

    toplevel.decoration = .{ .wlr_decoration = wlr_decoration };
    const decoration = &toplevel.decoration.?;

    wlr_decoration.events.destroy.add(&decoration.destroy);
    wlr_decoration.events.request_mode.add(&decoration.request_mode);

    if (toplevel.wlr_toplevel.base.initialized) {
        handleRequestMode(&decoration.request_mode, wlr_decoration);
    }
}

pub fn deinit(decoration: *XdgDecoration) void {
    const toplevel: *XdgToplevel = @ptrCast(@alignCast(decoration.wlr_decoration.toplevel.base.data));

    decoration.destroy.link.remove();
    decoration.request_mode.link.remove();

    assert(toplevel.decoration != null);
    toplevel.decoration = null;
}

fn handleDestroy(
    listener: *wl.Listener(*wlr.XdgToplevelDecorationV1),
    _: *wlr.XdgToplevelDecorationV1,
) void {
    const decoration: *XdgDecoration = @fieldParentPtr("destroy", listener);

    decoration.deinit();
}

fn handleRequestMode(
    listener: *wl.Listener(*wlr.XdgToplevelDecorationV1),
    _: *wlr.XdgToplevelDecorationV1,
) void {
    const decoration: *XdgDecoration = @fieldParentPtr("request_mode", listener);

    const toplevel: *XdgToplevel = @ptrCast(@alignCast(decoration.wlr_decoration.toplevel.base.data));
    const window = toplevel.window;

    window.setDecorationHint(switch (decoration.wlr_decoration.requested_mode) {
        .none => .no_preference,
        .client_side => .prefers_csd,
        .server_side => .prefers_ssd,
    });
}
