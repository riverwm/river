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

const PointerConstraint = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");

const log = std.log.scoped(.pointer_constraint);

wlr_constraint: *wlr.PointerConstraintV1,

state: union(enum) {
    inactive,
    active: struct {
        /// Node of the active constraint surface in the scene graph.
        node: *wlr.SceneNode,
        /// Coordinates of the pointer on activation in the surface coordinate system.
        sx: f64,
        sy: f64,
    },
} = .inactive,

destroy: wl.Listener(*wlr.PointerConstraintV1) = wl.Listener(*wlr.PointerConstraintV1).init(handleDestroy),
set_region: wl.Listener(void) = wl.Listener(void).init(handleSetRegion),

node_destroy: wl.Listener(void) = wl.Listener(void).init(handleNodeDestroy),

pub fn create(wlr_constraint: *wlr.PointerConstraintV1) error{OutOfMemory}!void {
    const seat: *Seat = @ptrFromInt(wlr_constraint.seat.data);

    const constraint = try util.gpa.create(PointerConstraint);
    errdefer util.gpa.destroy(constraint);

    constraint.* = .{
        .wlr_constraint = wlr_constraint,
    };
    wlr_constraint.data = @intFromPtr(constraint);

    wlr_constraint.events.destroy.add(&constraint.destroy);
    wlr_constraint.events.set_region.add(&constraint.set_region);

    if (seat.wlr_seat.keyboard_state.focused_surface) |surface| {
        if (surface == wlr_constraint.surface) {
            assert(seat.cursor.constraint == null);
            seat.cursor.constraint = constraint;
            constraint.maybeActivate();
        }
    }
}

pub fn maybeActivate(constraint: *PointerConstraint) void {
    const seat: *Seat = @ptrFromInt(constraint.wlr_constraint.seat.data);

    assert(seat.cursor.constraint == constraint);

    if (constraint.state == .active) return;

    if (seat.cursor.mode == .move or seat.cursor.mode == .resize) return;

    const result = server.root.at(seat.cursor.wlr_cursor.x, seat.cursor.wlr_cursor.y) orelse return;
    if (result.surface != constraint.wlr_constraint.surface) return;

    const sx: i32 = @intFromFloat(result.sx);
    const sy: i32 = @intFromFloat(result.sy);
    if (!constraint.wlr_constraint.region.containsPoint(sx, sy, null)) return;

    assert(constraint.state == .inactive);
    constraint.state = .{
        .active = .{
            .node = result.node,
            .sx = result.sx,
            .sy = result.sy,
        },
    };
    result.node.events.destroy.add(&constraint.node_destroy);

    log.info("activating pointer constraint", .{});

    constraint.wlr_constraint.sendActivated();
}

/// Called when the cursor position or content in the scene graph changes
pub fn updateState(constraint: *PointerConstraint) void {
    const seat: *Seat = @ptrFromInt(constraint.wlr_constraint.seat.data);

    constraint.maybeActivate();

    if (constraint.state != .active) return;

    var lx: i32 = undefined;
    var ly: i32 = undefined;
    if (!constraint.state.active.node.coords(&lx, &ly)) {
        log.info("deactivating pointer constraint, scene node disabled", .{});
        constraint.deactivate();
        return;
    }

    const sx = constraint.state.active.sx;
    const sy = constraint.state.active.sy;
    const warp_lx = @as(f64, @floatFromInt(lx)) + sx;
    const warp_ly = @as(f64, @floatFromInt(ly)) + sy;
    if (!seat.cursor.wlr_cursor.warp(null, warp_lx, warp_ly)) {
        log.info("deactivating pointer constraint, could not warp cursor", .{});
        constraint.deactivate();
        return;
    }

    // It is possible for the cursor to end up outside of the constraint region despite the warp
    // if, for example, the a keybinding is used to resize the view.
    if (!constraint.wlr_constraint.region.containsPoint(@intFromFloat(sx), @intFromFloat(sy), null)) {
        log.info("deactivating pointer constraint, cursor outside region despite warp", .{});
        constraint.deactivate();
        return;
    }
}

pub fn confine(constraint: *PointerConstraint, dx: *f64, dy: *f64) void {
    assert(constraint.state == .active);
    assert(constraint.wlr_constraint.type == .confined);

    const region = &constraint.wlr_constraint.region;
    const sx = constraint.state.active.sx;
    const sy = constraint.state.active.sy;
    var new_sx: f64 = undefined;
    var new_sy: f64 = undefined;
    assert(wlr.region.confine(region, sx, sy, sx + dx.*, sy + dy.*, &new_sx, &new_sy));

    dx.* = new_sx - sx;
    dy.* = new_sy - sy;

    constraint.state.active.sx = new_sx;
    constraint.state.active.sy = new_sy;
}

pub fn deactivate(constraint: *PointerConstraint) void {
    const seat: *Seat = @ptrFromInt(constraint.wlr_constraint.seat.data);

    assert(seat.cursor.constraint == constraint);
    assert(constraint.state == .active);

    constraint.warpToHintIfSet();

    constraint.state = .inactive;
    constraint.node_destroy.link.remove();
    constraint.wlr_constraint.sendDeactivated();
}

fn warpToHintIfSet(constraint: *PointerConstraint) void {
    const seat: *Seat = @ptrFromInt(constraint.wlr_constraint.seat.data);

    if (constraint.wlr_constraint.current.committed.cursor_hint) {
        var lx: i32 = undefined;
        var ly: i32 = undefined;
        _ = constraint.state.active.node.coords(&lx, &ly);

        const sx = constraint.wlr_constraint.current.cursor_hint.x;
        const sy = constraint.wlr_constraint.current.cursor_hint.y;
        _ = seat.cursor.wlr_cursor.warp(null, @as(f64, @floatFromInt(lx)) + sx, @as(f64, @floatFromInt(ly)) + sy);
        _ = seat.wlr_seat.pointerWarp(sx, sy);
    }
}

fn handleNodeDestroy(listener: *wl.Listener(void)) void {
    const constraint: *PointerConstraint = @fieldParentPtr("node_destroy", listener);

    log.info("deactivating pointer constraint, scene node destroyed", .{});
    constraint.deactivate();
}

fn handleDestroy(listener: *wl.Listener(*wlr.PointerConstraintV1), _: *wlr.PointerConstraintV1) void {
    const constraint: *PointerConstraint = @fieldParentPtr("destroy", listener);
    const seat: *Seat = @ptrFromInt(constraint.wlr_constraint.seat.data);

    if (constraint.state == .active) {
        // We can't simply call deactivate() here as it calls sendDeactivated(),
        // which could in the case of a oneshot constraint lifetime recursively
        // destroy the constraint.
        constraint.warpToHintIfSet();
        constraint.node_destroy.link.remove();
    }

    constraint.destroy.link.remove();
    constraint.set_region.link.remove();

    if (seat.cursor.constraint == constraint) {
        seat.cursor.constraint = null;
    }

    util.gpa.destroy(constraint);
}

fn handleSetRegion(listener: *wl.Listener(void)) void {
    const constraint: *PointerConstraint = @fieldParentPtr("set_region", listener);
    const seat: *Seat = @ptrFromInt(constraint.wlr_constraint.seat.data);

    switch (constraint.state) {
        .active => |state| {
            const sx: i32 = @intFromFloat(state.sx);
            const sy: i32 = @intFromFloat(state.sy);
            if (!constraint.wlr_constraint.region.containsPoint(sx, sy, null)) {
                log.info("deactivating pointer constraint, region change left pointer outside constraint", .{});
                constraint.deactivate();
            }
        },
        .inactive => {
            if (seat.cursor.constraint == constraint) {
                constraint.maybeActivate();
            }
        },
    }
}
