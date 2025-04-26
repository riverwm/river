// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2024 The River Developers
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

const TabletTool = @This();

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Tablet = @import("Tablet.zig");

const log = std.log.scoped(.tablet_tool);

const Mode = union(enum) {
    passthrough,
    down: struct {
        // Initial cursor position in layout coordinates
        lx: f64,
        ly: f64,
        // Initial cursor position in surface-local coordinates
        sx: f64,
        sy: f64,
    },
};

wp_tool: *wlr.TabletV2TabletTool,

wlr_cursor: *wlr.Cursor,

mode: Mode = .passthrough,

// A wlroots event may notify us of a change on one of these axes but not
// include the value of the other. We must always send both values to the
// client, which means we need to track this state.
tilt_x: f64 = 0,
tilt_y: f64 = 0,

destroy: wl.Listener(*wlr.TabletTool) = wl.Listener(*wlr.TabletTool).init(handleDestroy),
set_cursor: wl.Listener(*wlr.TabletV2TabletTool.event.SetCursor) =
    wl.Listener(*wlr.TabletV2TabletTool.event.SetCursor).init(handleSetCursor),

pub fn get(wlr_seat: *wlr.Seat, wlr_tool: *wlr.TabletTool) error{OutOfMemory}!*TabletTool {
    if (@as(?*TabletTool, @alignCast(@ptrCast(wlr_tool.data)))) |tool| {
        return tool;
    } else {
        return TabletTool.create(wlr_seat, wlr_tool);
    }
}

fn create(wlr_seat: *wlr.Seat, wlr_tool: *wlr.TabletTool) error{OutOfMemory}!*TabletTool {
    const tool = try util.gpa.create(TabletTool);
    errdefer util.gpa.destroy(tool);

    const wlr_cursor = try wlr.Cursor.create();
    errdefer wlr_cursor.destroy();

    wlr_cursor.attachOutputLayout(server.root.output_layout);

    const tablet_manager = server.input_manager.tablet_manager;
    tool.* = .{
        .wp_tool = try tablet_manager.createTabletV2TabletTool(wlr_seat, wlr_tool),
        .wlr_cursor = wlr_cursor,
    };

    wlr_tool.data = tool;

    wlr_tool.events.destroy.add(&tool.destroy);
    tool.wp_tool.events.set_cursor.add(&tool.set_cursor);

    return tool;
}

fn handleDestroy(listener: *wl.Listener(*wlr.TabletTool), _: *wlr.TabletTool) void {
    const tool: *TabletTool = @fieldParentPtr("destroy", listener);

    tool.wp_tool.wlr_tool.data = null;

    tool.wlr_cursor.destroy();

    tool.destroy.link.remove();
    tool.set_cursor.link.remove();

    util.gpa.destroy(tool);
}

pub fn allowSetCursor(tool: *TabletTool, seat_client: *wlr.Seat.Client, serial: u32) bool {
    if (tool.wp_tool.focused_surface == null or
        tool.wp_tool.focused_surface.?.resource.getClient() != seat_client.client)
    {
        log.debug("client tried to set cursor without focus", .{});
        return false;
    }
    if (serial != tool.wp_tool.proximity_serial) {
        log.debug("focused client tried to set cursor with incorrect serial", .{});
        return false;
    }
    return true;
}

fn handleSetCursor(
    listener: *wl.Listener(*wlr.TabletV2TabletTool.event.SetCursor),
    event: *wlr.TabletV2TabletTool.event.SetCursor,
) void {
    const tool: *TabletTool = @fieldParentPtr("set_cursor", listener);

    if (tool.allowSetCursor(event.seat_client, event.serial)) {
        tool.wlr_cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
    }
}

pub fn axis(tool: *TabletTool, tablet: *Tablet, event: *wlr.Tablet.event.Axis) void {
    tool.wlr_cursor.attachInputDevice(tablet.device.wlr_device);
    tool.wlr_cursor.mapInputToOutput(tablet.device.wlr_device, tablet.output_mapping);

    if (event.updated_axes.x or event.updated_axes.y) {
        // I don't own all these different types of tablet tools to test that this
        // is correct for each, this is best effort from reading code/docs.
        // The same goes for all the different axes events.
        switch (tool.wp_tool.wlr_tool.type) {
            .pen, .eraser, .brush, .pencil, .airbrush, .totem => {
                tool.wlr_cursor.warpAbsolute(
                    tablet.device.wlr_device,
                    if (event.updated_axes.x) event.x else math.nan(f64),
                    if (event.updated_axes.y) event.y else math.nan(f64),
                );
            },
            .lens, .mouse => {
                tool.wlr_cursor.move(tablet.device.wlr_device, event.dx, event.dy);
            },
        }

        switch (tool.mode) {
            .passthrough => {
                tool.passthrough(tablet);
            },
            .down => |data| {
                tool.wp_tool.notifyMotion(
                    data.sx + (tool.wlr_cursor.x - data.lx),
                    data.sy + (tool.wlr_cursor.y - data.ly),
                );
            },
        }
    }
    if (event.updated_axes.distance) {
        tool.wp_tool.notifyDistance(event.distance);
    }
    if (event.updated_axes.pressure) {
        tool.wp_tool.notifyPressure(event.pressure);
    }
    if (event.updated_axes.tilt_x or event.updated_axes.tilt_y) {
        if (event.updated_axes.tilt_x) tool.tilt_x = event.tilt_x;
        if (event.updated_axes.tilt_y) tool.tilt_y = event.tilt_y;

        tool.wp_tool.notifyTilt(tool.tilt_x, tool.tilt_y);
    }
    if (event.updated_axes.rotation) {
        tool.wp_tool.notifyRotation(event.rotation);
    }
    if (event.updated_axes.slider) {
        tool.wp_tool.notifySlider(event.slider);
    }
    if (event.updated_axes.wheel) {
        tool.wp_tool.notifyWheel(event.wheel_delta, 0);
    }
}

pub fn proximity(tool: *TabletTool, tablet: *Tablet, event: *wlr.Tablet.event.Proximity) void {
    switch (event.state) {
        .in => {
            tool.wlr_cursor.attachInputDevice(tablet.device.wlr_device);
            tool.wlr_cursor.mapInputToOutput(tablet.device.wlr_device, tablet.output_mapping);

            tool.wlr_cursor.warpAbsolute(tablet.device.wlr_device, event.x, event.y);

            tool.wlr_cursor.setXcursor(tablet.device.seat.cursor.xcursor_manager, "pencil");

            tool.passthrough(tablet);
        },
        .out => {
            tool.wp_tool.notifyProximityOut();
            tool.wlr_cursor.unsetImage();
        },
    }
}

pub fn tip(tool: *TabletTool, tablet: *Tablet, event: *wlr.Tablet.event.Tip) void {
    switch (event.state) {
        .down => {
            assert(!tool.wp_tool.is_down);

            tool.wp_tool.notifyDown();

            if (server.root.at(tool.wlr_cursor.x, tool.wlr_cursor.y)) |result| {
                if (result.surface != null) {
                    tool.mode = .{
                        .down = .{
                            .lx = tool.wlr_cursor.x,
                            .ly = tool.wlr_cursor.y,
                            .sx = result.sx,
                            .sy = result.sy,
                        },
                    };
                }
            }
        },
        .up => {
            assert(tool.wp_tool.is_down);

            tool.wp_tool.notifyUp();
            tool.maybeExitDown(tablet);
        },
    }
}

pub fn button(tool: *TabletTool, tablet: *Tablet, event: *wlr.Tablet.event.Button) void {
    tool.wp_tool.notifyButton(event.button, event.state);

    tool.maybeExitDown(tablet);
}

/// Exit down mode if the tool is up and there are no buttons pressed.
fn maybeExitDown(tool: *TabletTool, tablet: *Tablet) void {
    if (tool.mode != .down or tool.wp_tool.is_down or tool.wp_tool.num_buttons > 0) {
        return;
    }

    tool.mode = .passthrough;
    tool.passthrough(tablet);
}

/// Send a motion event for the surface under the tablet tool's cursor if any.
/// Send a proximity_in event first if needed.
/// If there is no surface under the cursor or the surface under the cursor
/// does not support the tablet v2 protocol, send a proximity_out event.
fn passthrough(tool: *TabletTool, tablet: *Tablet) void {
    if (server.root.at(tool.wlr_cursor.x, tool.wlr_cursor.y)) |result| {
        if (result.data == .lock_surface) {
            assert(server.lock_manager.state != .unlocked);
        } else {
            assert(server.lock_manager.state != .locked);
        }

        if (result.surface) |surface| {
            tool.wp_tool.notifyProximityIn(tablet.wp_tablet, surface);
            tool.wp_tool.notifyMotion(result.sx, result.sy);
            return;
        }
    } else {
        tool.wlr_cursor.setXcursor(tablet.device.seat.cursor.xcursor_manager, "pencil");
    }

    tool.wp_tool.notifyProximityOut();
}
