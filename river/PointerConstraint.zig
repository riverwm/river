const Self = @This();

const std = @import("std");

const c = @import("c.zig");
const util = @import("util.zig");

const Seat = @import("Seat.zig");
const Cursor = @import("Cursor.zig");
const View = @import("View.zig");

cursor: *Cursor,
constraint: ?*c.wlr_pointer_constraint_v1,

listen_set_region: c.wl_listener = undefined,
listen_destroy: c.wl_listener = undefined,

pub fn init(self: *Self, constraint: ?*c.wlr_pointer_constraint_v1) void {
    self.* = .{
        .cursor = &util.voidCast(Seat, constraint.?.seat.*.data.?).cursor,
        .constraint = constraint.?,
    };

    self.listen_set_region.notify = handleSetRegion;
    c.wl_signal_add(&constraint.?.events.set_region, &self.listen_set_region);

    self.listen_destroy.notify = handleDestroy;
    c.wl_signal_add(&constraint.?.events.destroy, &self.listen_destroy);

    const focus = &self.cursor.seat.focused;
    if (focus.* == .view and focus.view.wlr_surface != null) {
        if (focus.view.wlr_surface == constraint.?.surface) {
            if (self.cursor.active_constraint == constraint) {
                return;
            }

            c.wl_list_remove(&self.cursor.listen_constraint_commit.link);
            if (self.cursor.active_constraint != null) {
                if (constraint == null) {
                    self.warpToConstraintCursorHint();
                }
                c.wlr_pointer_constraint_v1_send_deactivated(
                    self.cursor.active_constraint);
            }

            self.cursor.active_constraint = constraint;

            if (constraint == null) {
                c.wl_list_init(&self.cursor.listen_constraint_commit.link);
                return;
            }

            self.cursor.active_confine_requires_warp = true;

            // FIXME: Big hack, stolen from wlr_pointer_constraints_v1.c:121 from sway.
            // This is necessary because the focus may be set before the surface
            // has finished committing, which means that warping won't work properly,
            // since this code will be run *after* the focus has been set.
            // That is why we duplicate the code here.
            if (c.pixman_region32_not_empty(&constraint.?.current.region) > 0) {
                const tst = c.pixman_region32_intersect(&constraint.?.region,
                    &constraint.?.surface.*.input_region, &constraint.?.current.region);
            } else {
                const tst = c.pixman_region32_copy(&constraint.?.region,
                    &constraint.?.surface.*.input_region);
            }

            checkRegion(self.cursor);

            c.wlr_pointer_constraint_v1_send_activated(constraint);

            self.cursor.listen_constraint_commit.notify = handleCommit;
            c.wl_signal_add(&constraint.?.surface.*.events.commit,
                &self.cursor.listen_constraint_commit);
        }
    }
}

fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_destroy", listener.?);
    const root = &self.cursor.seat.input_manager.server.root;
    const node = @fieldParentPtr(std.SinglyLinkedList(Self).Node, "data", self);
    root.pointer_constraints.remove(node);

    c.wl_list_remove(&self.listen_set_region.link);
    c.wl_list_remove(&self.listen_destroy.link);

    if (self.cursor.active_constraint == self.constraint) {
        self.warpToConstraintCursorHint();

        if (self.cursor.listen_constraint_commit.link.next != null) {
            c.wl_list_remove(&self.cursor.listen_constraint_commit.link);
        }
        //c.wl_list_init(&self.cursor.listen_constraint_commit.link);
        self.cursor.active_constraint = null;
    }

    util.gpa.destroy(node);
}

fn checkRegion(cursor: *Cursor) void {
    const constraint: ?*c.wlr_pointer_constraint_v1 = cursor.active_constraint;
    var region: *c.pixman_region32_t = &constraint.?.region;
    if (cursor.active_confine_requires_warp) {
        if (View.fromWlrSurface(constraint.?.surface)) |view| {
            cursor.active_confine_requires_warp = false;

            const cur = view.current;

            var sx: f64 = cursor.wlr_cursor.x - @intToFloat(f64, cur.box.x + view.surface_box.x);
            var sy: f64 = cursor.wlr_cursor.y - @intToFloat(f64, cur.box.y + view.surface_box.y);

            if (c.pixman_region32_contains_point(region, @floatToInt(c_int, @floor(sx)), @floatToInt(c_int, @floor(sy)), null,) != 1) {
                var nboxes: c_int = 0;
                const boxes: *c.pixman_box32_t = c.pixman_region32_rectangles(region, &nboxes);
                if (nboxes > 0) {
                    sx = @intToFloat(f64, (boxes.x1 + boxes.x2)) / 2.;
                    sy = @intToFloat(f64, (boxes.y1 + boxes.y2)) / 2.;

                    c.wlr_cursor_warp_closest(cursor.wlr_cursor, null, sx + @intToFloat(f64, cur.box.x - view.surface_box.x), sy + @intToFloat(f64, cur.box.y - view.surface_box.y),);
                }
            }
        }
    }

    if (constraint.?.type == .WLR_POINTER_CONSTRAINT_V1_CONFINED) {
        const tst = c.pixman_region32_copy(&cursor.confine, region,);
    } else {
        c.pixman_region32_clear(&cursor.confine);
    }
}

fn handleCommit(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const cursor: *Cursor = @fieldParentPtr(Cursor, "listen_constraint_commit", listener.?);
    std.debug.assert(cursor.active_constraint.?.surface == util.voidCast(c.wlr_surface, data.?));

    checkRegion(cursor);
}

fn handleSetRegion(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_set_region", listener.?);
    self.cursor.active_confine_requires_warp = true;
}

fn warpToConstraintCursorHint(self: *Self) void {
    const constraint: ?*c.wlr_pointer_constraint_v1 = self.cursor.active_constraint;

    if (constraint.?.current.committed > 0 and @intCast(u32, c.WLR_POINTER_CONSTRAINT_V1_STATE_CURSOR_HINT) > 0) {
        const sx: f64 = constraint.?.current.cursor_hint.x;
        const sy: f64 = constraint.?.current.cursor_hint.y;

        const view: ?*View = View.fromWlrSurface(constraint.?.surface);
        const cur = view.?.current;

        const lx: f64 = sx + @intToFloat(f64, cur.box.x + view.?.surface_box.x);
        const ly: f64 = sy + @intToFloat(f64, cur.box.y + view.?.surface_box.y);

        const asdf = c.wlr_cursor_warp(self.cursor.wlr_cursor, null, lx, ly);

        c.wlr_seat_pointer_warp(constraint.?.seat, sx, sy);
    }
}
