// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 - 2021 The River Developers
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

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Layout = @import("Layout.zig");
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const View = @import("View.zig");

const log = std.log.scoped(.layout);

const Error = error{ViewDimensionMismatch};

const timeout_ms = 100;

serial: u32,
/// Number of views for which dimensions have not been pushed.
/// This will go negative if the client pushes too many dimensions.
views: i32,
/// Proposed view dimensions
view_boxen: []wlr.Box,
timeout_timer: *wl.EventSource,

pub fn init(layout: *Layout, views: u32) !Self {
    const event_loop = server.wl_server.getEventLoop();
    const timeout_timer = try event_loop.addTimer(*Layout, handleTimeout, layout);
    errdefer timeout_timer.remove();
    try timeout_timer.timerUpdate(timeout_ms);

    return Self{
        .serial = server.wl_server.nextSerial(),
        .views = @intCast(i32, views),
        .view_boxen = try util.gpa.alloc(wlr.Box, views),
        .timeout_timer = timeout_timer,
    };
}

pub fn deinit(self: *const Self) void {
    self.timeout_timer.remove();
    util.gpa.free(self.view_boxen);
}

/// Destroy the LayoutDemand on timeout.
/// All further responses to the event will simply be ignored.
fn handleTimeout(layout: *Layout) c_int {
    log.info(
        "layout demand for layout '{s}' on output '{s}' timed out",
        .{ layout.namespace, layout.output.wlr_output.name },
    );
    layout.output.inflight.layout_demand.?.deinit();
    layout.output.inflight.layout_demand = null;

    server.root.notifyLayoutDemandDone();

    return 0;
}

/// Push a set of proposed view dimensions and position to the list
pub fn pushViewDimensions(self: *Self, x: i32, y: i32, width: u31, height: u31) void {
    // The client pushed too many dimensions
    if (self.views <= 0) {
        self.views -= 1;
        return;
    }

    self.view_boxen[self.view_boxen.len - @intCast(usize, self.views)] = .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
    };

    self.views -= 1;
}

/// Apply the proposed layout to the output
pub fn apply(self: *Self, layout: *Layout) void {
    // Note: output.layout may not be equal to layout here if the layout
    // namespace changes while a transactions is inflight.
    const output = layout.output;

    // Whether the layout demand succeeds or fails, we are done with it and
    // need to clean up
    defer {
        output.inflight.layout_demand.?.deinit();
        output.inflight.layout_demand = null;
        server.root.notifyLayoutDemandDone();
    }

    // Check that the number of proposed dimensions is correct.
    if (self.views != 0) {
        log.err(
            "proposed dimension count ({}) does not match view count ({}), aborting layout demand",
            .{ -self.views + @intCast(i32, self.view_boxen.len), self.view_boxen.len },
        );
        layout.layout.postError(
            .count_mismatch,
            "number of proposed view dimensions must match number of views",
        );
        return;
    }

    // Apply proposed layout to the inflight state of the target views
    var it = output.inflight.wm_stack.iterator(.forward);
    var i: u32 = 0;
    while (it.next()) |view| {
        if (!view.inflight.float and !view.inflight.fullscreen and
            view.inflight.tags & output.inflight.tags != 0)
        {
            const proposed = &self.view_boxen[i];

            // Here we apply the offset to align the coords with the origin of the
            // usable area and shrink the dimensions to accommodate the border size.
            const border_width = if (view.inflight.ssd) server.config.border_width else 0;
            view.inflight.box = .{
                .x = proposed.x + output.usable_box.x + border_width,
                .y = proposed.y + output.usable_box.y + border_width,
                .width = proposed.width - 2 * border_width,
                .height = proposed.height - 2 * border_width,
            };

            view.applyConstraints(&view.inflight.box);

            // State flowing "backwards" like this is pretty ugly, but I don't
            // see a better way to sync this up right now.
            if (!view.pending.float and !view.pending.fullscreen) {
                view.pending.box = view.inflight.box;
            }

            i += 1;
        }
    }
    assert(i == self.view_boxen.len);
}
