// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const Self = @This();

const build_options = @import("build_options");
const std = @import("std");

const c = @import("c.zig");
const log = @import("log.zig");
const util = @import("util.zig");

const Seat = @import("Seat.zig");
const Server = @import("Server.zig");
const View = @import("View.zig");

const Cursor = @import("Cursor.zig");

const default_seat_name = "default";

server: *Server,

wlr_idle: *c.wlr_idle,
wlr_input_inhibit_manager: *c.wlr_input_inhibit_manager,
wlr_pointer_constraints: *c.wlr_pointer_constraints_v1,

seats: std.TailQueue(Seat) = .{},

exclusive_client: ?*c.wl_client = null,

listen_inhibit_activate: c.wl_listener = undefined,
listen_inhibit_deactivate: c.wl_listener = undefined,
listen_new_input: c.wl_listener = undefined,
listen_new_pointer_constraint: c.wl_listener = undefined,

pub fn init(self: *Self, server: *Server) !void {
    const seat_node = try util.gpa.create(std.TailQueue(Seat).Node);

    self.* = .{
        .server = server,
        // These are automatically freed when the display is destroyed
        .wlr_idle = c.wlr_idle_create(server.wl_display) orelse return error.OutOfMemory,
        .wlr_input_inhibit_manager = c.wlr_input_inhibit_manager_create(server.wl_display) orelse
            return error.OutOfMemory,
        .wlr_pointer_constraints = c.wlr_pointer_constraints_v1_create(server.wl_display) orelse
            return error.OutOfMemory,
    };

    self.seats.prepend(seat_node);
    try seat_node.data.init(self, default_seat_name);

    if (build_options.xwayland) c.wlr_xwayland_set_seat(server.wlr_xwayland, self.defaultSeat().wlr_seat);

    // Set up all listeners
    self.listen_inhibit_activate.notify = handleInhibitActivate;
    c.wl_signal_add(&self.wlr_input_inhibit_manager.events.activate, &self.listen_inhibit_activate);

    self.listen_inhibit_deactivate.notify = handleInhibitDeactivate;
    c.wl_signal_add(&self.wlr_input_inhibit_manager.events.deactivate, &self.listen_inhibit_deactivate);

    self.listen_new_input.notify = handleNewInput;
    c.wl_signal_add(&self.server.wlr_backend.events.new_input, &self.listen_new_input);

    self.listen_new_pointer_constraint.notify = handleNewPointerConstraint;
    c.wl_signal_add(&self.wlr_pointer_constraints.events.new_constraint, &self.listen_new_pointer_constraint);
}

pub fn deinit(self: *Self) void {
    while (self.seats.pop()) |seat_node| {
        seat_node.data.deinit();
        util.gpa.destroy(seat_node);
    }
}

pub fn defaultSeat(self: Self) *Seat {
    return &self.seats.first.?.data;
}

/// Must be called whenever a view is unmapped.
pub fn handleViewUnmap(self: Self, view: *View) void {
    var it = self.seats.first;
    while (it) |node| : (it = node.next) {
        const seat = &node.data;
        seat.handleViewUnmap(view);
    }
}

/// Returns true if input is currently allowed on the passed surface.
pub fn inputAllowed(self: Self, wlr_surface: *c.wlr_surface) bool {
    return if (self.exclusive_client) |exclusive_client|
        exclusive_client == c.wl_resource_get_client(wlr_surface.resource)
    else
        true;
}

pub fn isCursorActionTarget(self: Self, view: *View) bool {
    var it = self.seats.first;
    return while (it) |node| : (it = node.next) {
        if (node.data.cursor.isCursorActionTarget(view)) break true;
    } else false;
}

fn handleInhibitActivate(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_inhibit_activate", listener.?);

    log.debug(.input_manager, "input inhibitor activated", .{});

    // Clear focus of all seats
    var seat_it = self.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        seat_node.data.setFocusRaw(.{ .none = {} });
    }

    self.exclusive_client = self.wlr_input_inhibit_manager.active_client;
}

fn handleInhibitDeactivate(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_inhibit_deactivate", listener.?);

    log.debug(.input_manager, "input inhibitor deactivated", .{});

    self.exclusive_client = null;

    // Calling arrangeLayers() like this ensures that any top or overlay,
    // keyboard-interactive surfaces will re-grab focus.
    var output_it = self.server.root.outputs.first;
    while (output_it) |output_node| : (output_it = output_node.next) {
        output_node.data.arrangeLayers();
    }

    // After ensuring that any possible layer surface focus grab has occured,
    // have each Seat handle focus.
    var seat_it = self.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        seat_node.data.focus(null);
    }

    self.server.root.startTransaction();
}

/// This event is raised by the backend when a new input device becomes available.
fn handleNewInput(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_new_input", listener.?);
    const device = util.voidCast(c.wlr_input_device, data.?);

    // TODO: suport multiple seats
    self.defaultSeat().addDevice(device);
}

const struct_pointer_constraint = struct {
    cursor: *Cursor,
    constraint: *c.wlr_pointer_constraint_v1,
    set_region: c.wl_listener,
    destroy: c.wl_listener,
};
/// This event is raised when a new pointer constraint
fn handleNewPointerConstraint(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_new_pointer_constraint", listener.?);
    const constraint = util.voidCast(c.wlr_pointer_constraint_v1, data.?);
    const cursor = &self.defaultSeat().cursor;
    const pointer_constraint = util.gpa.create(struct_pointer_constraint) catch {
        return;
    };
    pointer_constraint.cursor = cursor;
    pointer_constraint.constraint = constraint;

    pointer_constraint.set_region.notify = handlePointerConstraintSetRegion;
    c.wl_signal_add(&constraint.events.set_region, &pointer_constraint.set_region);

    pointer_constraint.destroy.notify = handlePointerConstraintDestroy;
    c.wl_signal_add(&constraint.events.destroy, &pointer_constraint.destroy);

    if (cursor.seat.focused.view.wlr_surface == constraint.surface) {
        //c.wl_list_remove(&cursor.constraint_commit.link);
        //if (cursor.active_constraint != undefined) {
        //    //if (constraint == NULL) {
        //    //    warp_to_constraint_cursor_hint(cursor);
        //    //}
        //    c.wlr_pointer_constraint_v1_send_deactivated(
        //        cursor.active_constraint);
        //}

        cursor.active_constraint = constraint;

        //if (constraint == undefined) {
        //    c.wl_list_init(&cursor.constraint_commit.link);
        //    return;
        //}

        cursor.active_confine_requires_warp = true;

        //check_constraint_region(cursor);

        c.wlr_pointer_constraint_v1_send_activated(constraint);

        //cursor.constraint_commit.notify = handle_constraint_commit;
        //c.wl_signal_add(&constraint.surface.events.commit,
        //    &cursor.constraint_commit);
    }
}


fn handlePointerConstraintSetRegion(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
}
fn handlePointerConstraintDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const pointer_constraint = @fieldParentPtr(struct_pointer_constraint, "destroy", listener.?);
    const constraint = util.voidCast(c.wlr_pointer_constraint_v1, data.?);

    c.wl_list_remove(&pointer_constraint.set_region.link);
    c.wl_list_remove(&pointer_constraint.destroy.link);

    if (pointer_constraint.cursor.active_constraint == constraint) {
        pointer_constraint.cursor.active_constraint = null;
    }

    util.gpa.destroy(pointer_constraint);
}
