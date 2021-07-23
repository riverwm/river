// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 - 2021 The River Developers
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
const mem = std.mem;
const ascii = std.ascii;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const InputConfig = @import("InputConfig.zig");
const Seat = @import("Seat.zig");
const Server = @import("Server.zig");
const View = @import("View.zig");
const PointerConstraint = @import("PointerConstraint.zig");

const default_seat_name = "default";

const log = std.log.scoped(.input_manager);

pub const InputDevice = struct {
    device: *wlr.InputDevice,
    destroy: wl.Listener(*wlr.InputDevice) = wl.Listener(*wlr.InputDevice).init(handleDestroy),

    /// Careful: The identifier is not unique! A physical input device may have
    /// multiple logical input devices with the exact same vendor id, product id
    /// and name. However identifiers of InputConfigs are unique.
    identifier: []const u8,

    pub fn init(self: *InputDevice, device: *wlr.InputDevice) !void {
        // The identifier is formatted exactly as in Sway
        const identifier = try std.fmt.allocPrint(
            util.gpa,
            "{}:{}:{s}",
            .{ device.vendor, device.product, mem.trim(
                u8,
                mem.sliceTo(device.name, 0),
                &ascii.spaces,
            ) },
        );
        for (identifier) |*char| {
            if (char.* == ' ' or !std.ascii.isPrint(char.*)) {
                char.* = '_';
            }
        }
        self.* = .{
            .device = device,
            .identifier = identifier,
        };
        log.debug("new input device: {s}", .{self.identifier});
        device.events.destroy.add(&self.destroy);
    }

    pub fn deinit(self: *InputDevice) void {
        util.gpa.free(self.identifier);
        self.destroy.link.remove();
    }

    fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
        const self = @fieldParentPtr(InputDevice, "destroy", listener);
        log.debug("removed input device: {s}", .{self.identifier});
        self.deinit();

        const node = @fieldParentPtr(std.TailQueue(InputDevice).Node, "data", self);
        server.input_manager.input_devices.remove(node);
        util.gpa.destroy(node);
    }
};

new_input: wl.Listener(*wlr.InputDevice) = wl.Listener(*wlr.InputDevice).init(handleNewInput),

idle: *wlr.Idle,
input_inhibit_manager: *wlr.InputInhibitManager,
pointer_constraints: *wlr.PointerConstraintsV1,
relative_pointer_manager: *wlr.RelativePointerManagerV1,
virtual_pointer_manager: *wlr.VirtualPointerManagerV1,
virtual_keyboard_manager: *wlr.VirtualKeyboardManagerV1,

input_configs: std.ArrayList(InputConfig),
input_devices: std.TailQueue(InputDevice) = .{},
seats: std.TailQueue(Seat) = .{},

exclusive_client: ?*wl.Client = null,

inhibit_activate: wl.Listener(*wlr.InputInhibitManager) =
    wl.Listener(*wlr.InputInhibitManager).init(handleInhibitActivate),
inhibit_deactivate: wl.Listener(*wlr.InputInhibitManager) =
    wl.Listener(*wlr.InputInhibitManager).init(handleInhibitDeactivate),
new_pointer_constraint: wl.Listener(*wlr.PointerConstraintV1) =
    wl.Listener(*wlr.PointerConstraintV1).init(handleNewPointerConstraint),
new_virtual_pointer: wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer) =
    wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer).init(handleNewVirtualPointer),
new_virtual_keyboard: wl.Listener(*wlr.VirtualKeyboardV1) =
    wl.Listener(*wlr.VirtualKeyboardV1).init(handleNewVirtualKeyboard),

pub fn init(self: *Self) !void {
    const seat_node = try util.gpa.create(std.TailQueue(Seat).Node);
    errdefer util.gpa.destroy(seat_node);

    self.* = .{
        // These are automatically freed when the display is destroyed
        .idle = try wlr.Idle.create(server.wl_server),
        .input_inhibit_manager = try wlr.InputInhibitManager.create(server.wl_server),
        .pointer_constraints = try wlr.PointerConstraintsV1.create(server.wl_server),
        .relative_pointer_manager = try wlr.RelativePointerManagerV1.create(server.wl_server),
        .virtual_pointer_manager = try wlr.VirtualPointerManagerV1.create(server.wl_server),
        .virtual_keyboard_manager = try wlr.VirtualKeyboardManagerV1.create(server.wl_server),
        .input_configs = std.ArrayList(InputConfig).init(util.gpa),
    };

    self.seats.prepend(seat_node);
    try seat_node.data.init(default_seat_name);

    if (build_options.xwayland) server.xwayland.setSeat(self.defaultSeat().wlr_seat);

    server.backend.events.new_input.add(&self.new_input);
    self.input_inhibit_manager.events.activate.add(&self.inhibit_activate);
    self.input_inhibit_manager.events.deactivate.add(&self.inhibit_deactivate);
    self.pointer_constraints.events.new_constraint.add(&self.new_pointer_constraint);
    self.virtual_pointer_manager.events.new_virtual_pointer.add(&self.new_virtual_pointer);
    self.virtual_keyboard_manager.events.new_virtual_keyboard.add(&self.new_virtual_keyboard);
}

pub fn deinit(self: *Self) void {
    while (self.seats.pop()) |seat_node| {
        seat_node.data.deinit();
        util.gpa.destroy(seat_node);
    }

    while (self.input_devices.pop()) |input_device_node| {
        input_device_node.data.deinit();
        util.gpa.destroy(input_device_node);
    }

    for (self.input_configs.items) |*input_config| {
        input_config.deinit();
    }
    self.input_configs.deinit();
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
pub fn inputAllowed(self: Self, wlr_surface: *wlr.Surface) bool {
    return if (self.exclusive_client) |exclusive_client|
        exclusive_client == wlr_surface.resource.getClient()
    else
        true;
}

pub fn updateCursorState(self: Self) void {
    var it = self.seats.first;
    while (it) |node| : (it = node.next) node.data.cursor.updateState();
}

fn handleInhibitActivate(
    listener: *wl.Listener(*wlr.InputInhibitManager),
    input_inhibit_manager: *wlr.InputInhibitManager,
) void {
    const self = @fieldParentPtr(Self, "inhibit_activate", listener);

    log.debug("input inhibitor activated", .{});

    var seat_it = self.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        // Clear focus of all seats
        seat_node.data.setFocusRaw(.{ .none = {} });

        // Enter locked mode
        seat_node.data.prev_mode_id = seat_node.data.mode_id;
        seat_node.data.mode_id = 1;
    }

    self.exclusive_client = self.input_inhibit_manager.active_client;
}

fn handleInhibitDeactivate(
    listener: *wl.Listener(*wlr.InputInhibitManager),
    input_inhibit_manager: *wlr.InputInhibitManager,
) void {
    const self = @fieldParentPtr(Self, "inhibit_deactivate", listener);

    log.debug("input inhibitor deactivated", .{});

    self.exclusive_client = null;

    // Calling arrangeLayers() like this ensures that any top or overlay,
    // keyboard-interactive surfaces will re-grab focus.
    var output_it = server.root.outputs.first;
    while (output_it) |output_node| : (output_it = output_node.next) {
        output_node.data.arrangeLayers(.mapped);
    }

    // After ensuring that any possible layer surface focus grab has occured,
    // have each Seat handle focus and enter their previous mode.
    var seat_it = self.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        seat_node.data.focus(null);
        seat_node.data.mode_id = seat_node.data.prev_mode_id;
    }

    server.root.startTransaction();
}

/// This event is raised by the backend when a new input device becomes available.
fn handleNewInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
    const self = @fieldParentPtr(Self, "new_input", listener);
    // TODO: support multiple seats

    const input_device_node = util.gpa.create(std.TailQueue(InputDevice).Node) catch return;
    input_device_node.data.init(device) catch {
        util.gpa.destroy(input_device_node);
        return;
    };
    self.input_devices.append(input_device_node);
    self.defaultSeat().addDevice(device);

    // Apply matching input device configuration, if exists.
    for (self.input_configs.items) |*input_config| {
        if (mem.eql(u8, input_config.identifier, mem.sliceTo(input_device_node.data.identifier, 0))) {
            input_config.apply(&input_device_node.data);
            break; // There will only ever be one InputConfig for any unique identifier;
        }
    }
}

fn handleNewPointerConstraint(listener: *wl.Listener(*wlr.PointerConstraintV1), constraint: *wlr.PointerConstraintV1) void {
    const pointer_constraint = util.gpa.create(PointerConstraint) catch {
        log.crit("out of memory", .{});
        return;
    };

    pointer_constraint.init(constraint);
}

fn handleNewVirtualPointer(
    listener: *wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer),
    event: *wlr.VirtualPointerManagerV1.event.NewPointer,
) void {
    const self = @fieldParentPtr(Self, "new_virtual_pointer", listener);

    // TODO Support multiple seats and don't ignore
    if (event.suggested_seat != null) {
        log.debug("Ignoring seat suggestion from virtual pointer", .{});
    }
    // TODO dont ignore output suggestion
    if (event.suggested_output != null) {
        log.debug("Ignoring output suggestion from virtual pointer", .{});
    }

    self.defaultSeat().addDevice(&event.new_pointer.input_device);
}

fn handleNewVirtualKeyboard(
    listener: *wl.Listener(*wlr.VirtualKeyboardV1),
    virtual_keyboard: *wlr.VirtualKeyboardV1,
) void {
    const self = @fieldParentPtr(Self, "new_virtual_keyboard", listener);
    const seat = @intToPtr(*Seat, virtual_keyboard.seat.data);
    seat.addDevice(&virtual_keyboard.input_device);
}
