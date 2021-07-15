// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");

const command = @import("command.zig");
const server = &@import("main.zig").server;
const util = @import("util.zig");

const DragIcon = @import("DragIcon.zig");
const Cursor = @import("Cursor.zig");
const InputManager = @import("InputManager.zig");
const Keyboard = @import("Keyboard.zig");
const LayerSurface = @import("LayerSurface.zig");
const Output = @import("Output.zig");
const SeatStatus = @import("SeatStatus.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;

const log = std.log.scoped(.seat);
const PointerConstraint = @import("PointerConstraint.zig");

const FocusTarget = union(enum) {
    view: *View,
    layer: *LayerSurface,
    none: void,
};

wlr_seat: *wlr.Seat,

/// Multiple mice are handled by the same Cursor
cursor: Cursor = undefined,

/// Mulitple keyboards are handled separately
keyboards: std.TailQueue(Keyboard) = .{},

/// ID of the current keymap mode
mode_id: usize = 0,

/// ID of previous keymap mode, used when returning from "locked" mode
prev_mode_id: usize = 0,

/// Currently focused output, may be the noop output if no real output
/// is currently available for focus.
focused_output: *Output,

/// Currently focused view/layer surface if any
focused: FocusTarget = .none,

/// Stack of views in most recently focused order
/// If there is a currently focused view, it is on top.
focus_stack: ViewStack(*View) = .{},

/// List of status tracking objects relaying changes to this seat to clients.
status_trackers: std.SinglyLinkedList(SeatStatus) = .{},

request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) =
    wl.Listener(*wlr.Seat.event.RequestSetSelection).init(handleRequestSetSelection),
request_start_drag: wl.Listener(*wlr.Seat.event.RequestStartDrag) =
    wl.Listener(*wlr.Seat.event.RequestStartDrag).init(handleRequestStartDrag),
start_drag: wl.Listener(*wlr.Drag) = wl.Listener(*wlr.Drag).init(handleStartDrag),
request_set_primary_selection: wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection) =
    wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection).init(handleRequestSetPrimarySelection),

pub fn init(self: *Self, name: [*:0]const u8) !void {
    self.* = .{
        // This will be automatically destroyed when the display is destroyed
        .wlr_seat = try wlr.Seat.create(server.wl_server, name),
        .focused_output = &server.root.noop_output,
    };
    self.wlr_seat.data = @ptrToInt(self);

    try self.cursor.init(self);

    self.wlr_seat.events.request_set_selection.add(&self.request_set_selection);
    self.wlr_seat.events.request_start_drag.add(&self.request_start_drag);
    self.wlr_seat.events.start_drag.add(&self.start_drag);
    self.wlr_seat.events.request_set_primary_selection.add(&self.request_set_primary_selection);
}

pub fn deinit(self: *Self) void {
    self.cursor.deinit();

    while (self.keyboards.pop()) |node| {
        node.data.deinit();
        util.gpa.destroy(node);
    }

    while (self.focus_stack.first) |node| {
        self.focus_stack.remove(node);
        util.gpa.destroy(node);
    }
}

/// Set the current focus. If a visible view is passed it will be focused.
/// If null is passed, the first visible view in the focus stack will be focused.
pub fn focus(self: *Self, _target: ?*View) void {
    var target = _target;

    // While a layer surface is focused, views may not recieve focus
    if (self.focused == .layer) return;

    if (target) |view| {
        // If the view is not currently visible, behave as if null was passed
        if (view.pending.tags & view.output.pending.tags == 0) {
            target = null;
        } else {
            // If the view is not on the currently focused output, focus it
            if (view.output != self.focused_output) self.focusOutput(view.output);
        }
    }

    // If the target view is not fullscreen or null, then a fullscreen view
    // will grab focus if visible.
    if (if (target) |v| !v.pending.fullscreen else true) {
        const tags = self.focused_output.pending.tags;
        var it = ViewStack(*View).iter(self.focus_stack.first, .forward, tags, pendingFilter);
        target = while (it.next()) |view| {
            if (view.output == self.focused_output and view.pending.fullscreen) break view;
        } else target;
    }

    if (target == null) {
        // Set view to the first currently visible view in the focus stack if any
        const tags = self.focused_output.pending.tags;
        var it = ViewStack(*View).iter(self.focus_stack.first, .forward, tags, pendingFilter);
        target = while (it.next()) |view| {
            if (view.output == self.focused_output) break view;
        } else null;
    }

    if (target) |view| {
        // Find or allocate a new node in the focus stack for the target view
        var it = self.focus_stack.first;
        while (it) |node| : (it = node.next) {
            // If the view is found, move it to the top of the stack
            if (node.view == view) {
                const new_focus_node = self.focus_stack.remove(node);
                self.focus_stack.push(node);
                break;
            }
        } else {
            // The view is not in the stack, so allocate a new node and prepend it
            const new_focus_node = util.gpa.create(ViewStack(*View).Node) catch return;
            new_focus_node.view = view;
            self.focus_stack.push(new_focus_node);
        }

        // Focus the target view
        self.setFocusRaw(.{ .view = view });
    } else {
        // Otherwise clear the focus
        self.setFocusRaw(.{ .none = {} });
    }
}

fn pendingFilter(view: *View, filter_tags: u32) bool {
    return !view.destroying and view.pending.tags & filter_tags != 0;
}

/// Switch focus to the target, handling unfocus and input inhibition
/// properly. This should only be called directly if dealing with layers.
pub fn setFocusRaw(self: *Self, new_focus: FocusTarget) void {
    // If the target is already focused, do nothing
    if (std.meta.eql(new_focus, self.focused)) return;

    // Obtain the target surface
    const target_surface = switch (new_focus) {
        .view => |target_view| target_view.surface.?,
        .layer => |target_layer| target_layer.wlr_layer_surface.surface,
        .none => null,
    };

    // If input is not allowed on the target surface (e.g. due to an active
    // input inhibitor) do not set focus. If there is no target surface we
    // still clear the focus.
    if (if (target_surface) |wlr_surface| server.input_manager.inputAllowed(wlr_surface) else true) {
        // First clear the current focus
        switch (self.focused) {
            .view => |view| {
                view.pending.focus -= 1;
                if (view.pending.focus == 0) view.setActivated(false);
            },
            .layer, .none => {},
        }

        // Set the new focus
        switch (new_focus) {
            .view => |target_view| {
                std.debug.assert(self.focused_output == target_view.output);
                if (target_view.pending.focus == 0) target_view.setActivated(true);
                target_view.pending.focus += 1;
            },
            .layer => |target_layer| std.debug.assert(self.focused_output == target_layer.output),
            .none => {},
        }
        self.focused = new_focus;

        // Send keyboard enter/leave events and handle pointer constraints
        if (target_surface) |wlr_surface| {
            if (self.wlr_seat.getKeyboard()) |keyboard| {
                self.wlr_seat.keyboardNotifyEnter(
                    wlr_surface,
                    &keyboard.keycodes,
                    keyboard.num_keycodes,
                    &keyboard.modifiers,
                );
            } else {
                self.wlr_seat.keyboardNotifyEnter(wlr_surface, null, 0, null);
            }

            if (server.input_manager.pointer_constraints.constraintForSurface(wlr_surface, self.wlr_seat)) |constraint| {
                @intToPtr(*PointerConstraint, constraint.data).setAsActive();
            } else if (self.cursor.constraint) |constraint| {
                PointerConstraint.warpToHint(&self.cursor);
                constraint.sendDeactivated();
                self.cursor.constraint = null;
            }
        } else {
            self.wlr_seat.keyboardClearFocus();

            if (self.cursor.constraint) |constraint| {
                PointerConstraint.warpToHint(&self.cursor);
                constraint.sendDeactivated();
                self.cursor.constraint = null;
            }
        }
    }

    // Inform any clients tracking status of the change
    var it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendFocusedView();
}

/// Focus the given output, notifying any listening clients of the change.
pub fn focusOutput(self: *Self, output: *Output) void {
    if (self.focused_output == output) return;

    // Warp pointer to center of newly focused output (In layout coordinates),
    // but only if cursor is not already on the output and this feature is enabled.
    switch (server.config.warp_cursor) {
        .disabled => {},
        .@"on-output-change" => {
            const layout_box = server.root.output_layout.getBox(output.wlr_output).?;
            if (!layout_box.containsPoint(self.cursor.wlr_cursor.x, self.cursor.wlr_cursor.y)) {
                const eff_res = output.getEffectiveResolution();
                const lx = @intToFloat(f32, layout_box.x + @intCast(i32, eff_res.width / 2));
                const ly = @intToFloat(f32, layout_box.y + @intCast(i32, eff_res.height / 2));
                if (!self.cursor.wlr_cursor.warp(null, lx, ly)) {
                    log.err("failed to warp cursor on output change", .{});
                }
            }
        },
    }

    var it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendOutput(.unfocused);

    self.focused_output = output;

    it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendOutput(.focused);
}

pub fn handleActivity(self: Self) void {
    server.input_manager.idle.notifyActivity(self.wlr_seat);
}

/// Handle the unmapping of a view, removing it from the focus stack and
/// setting the focus if needed.
pub fn handleViewUnmap(self: *Self, view: *View) void {
    // Remove the node from the focus stack and destroy it.
    var it = self.focus_stack.first;
    while (it) |node| : (it = node.next) {
        if (node.view == view) {
            self.focus_stack.remove(node);
            util.gpa.destroy(node);
            break;
        }
    }

    self.cursor.handleViewUnmap(view);

    // If the unmapped view is focused, choose a new focus
    if (self.focused == .view and self.focused.view == view) self.focus(null);
}

/// Handle any user-defined mapping for the passed keysym and modifiers
/// Returns true if the key was handled
pub fn handleMapping(
    self: *Self,
    keysym: xkb.Keysym,
    modifiers: wlr.Keyboard.ModifierMask,
    released: bool,
) bool {
    const modes = &server.config.modes;
    for (modes.items[self.mode_id].mappings.items) |mapping| {
        if (std.meta.eql(modifiers, mapping.modifiers) and keysym == mapping.keysym and released == mapping.release) {
            // Execute the bound command
            const args = mapping.command_args;
            var out: ?[]const u8 = null;
            defer if (out) |s| util.gpa.free(s);
            command.run(util.gpa, self, args, &out) catch |err| {
                const failure_message = switch (err) {
                    command.Error.Other => out.?,
                    else => command.errToMsg(err),
                };
                std.log.scoped(.command).err("{s}: {s}", .{ args[0], failure_message });
                return true;
            };
            if (out) |s| {
                const stdout = std.io.getStdOut().writer();
                stdout.print("{s}", .{s}) catch |err| {
                    std.log.scoped(.command).err("{s}: write to stdout failed {}", .{ args[0], err });
                };
            }
            return true;
        }
    }
    return false;
}

/// Add a newly created input device to the seat and update the reported
/// capabilities.
pub fn addDevice(self: *Self, device: *wlr.InputDevice) void {
    switch (device.type) {
        .keyboard => self.addKeyboard(device) catch return,
        .pointer => self.addPointer(device),
        else => return,
    }

    // We need to let the wlr_seat know what our capabilities are, which is
    // communiciated to the client. We always have a cursor, even if
    // there are no pointer devices, so we always include that capability.
    self.wlr_seat.setCapabilities(.{
        .pointer = true,
        .keyboard = self.keyboards.len > 0,
    });
}

fn addKeyboard(self: *Self, device: *wlr.InputDevice) !void {
    const node = try util.gpa.create(std.TailQueue(Keyboard).Node);
    node.data.init(self, device) catch |err| {
        const log_keyboard = std.log.scoped(.keyboard);
        switch (err) {
            error.XkbContextFailed => log_keyboard.err("Failed to create XKB context", .{}),
            error.XkbKeymapFailed => log_keyboard.err("Failed to create XKB keymap", .{}),
            error.SetKeymapFailed => log_keyboard.err("Failed to set wlr keyboard keymap", .{}),
        }
        return;
    };
    self.keyboards.append(node);
    self.wlr_seat.setKeyboard(device);
}

fn addPointer(self: Self, device: *wlr.InputDevice) void {
    // We don't do anything special with pointers. All of our pointer handling
    // is proxied through wlr_cursor. On another compositor, you might take this
    // opportunity to do libinput configuration on the device to set
    // acceleration, etc.
    self.cursor.wlr_cursor.attachInputDevice(device);
}

fn handleRequestSetSelection(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
    event: *wlr.Seat.event.RequestSetSelection,
) void {
    const self = @fieldParentPtr(Self, "request_set_selection", listener);
    self.wlr_seat.setSelection(event.source, event.serial);
}

fn handleRequestStartDrag(
    listener: *wl.Listener(*wlr.Seat.event.RequestStartDrag),
    event: *wlr.Seat.event.RequestStartDrag,
) void {
    const self = @fieldParentPtr(Self, "request_start_drag", listener);

    if (!self.wlr_seat.validatePointerGrabSerial(event.origin, event.serial)) {
        log.debug("ignoring request to start drag, failed to validate serial {}", .{event.serial});
        if (event.drag.source) |source| source.destroy();
        return;
    }

    log.debug("starting pointer drag", .{});
    self.wlr_seat.startPointerDrag(event.drag, event.serial);
}

fn handleStartDrag(
    listener: *wl.Listener(*wlr.Drag),
    wlr_drag: *wlr.Drag,
) void {
    const self = @fieldParentPtr(Self, "start_drag", listener);

    if (wlr_drag.icon) |wlr_drag_icon| {
        const node = util.gpa.create(std.SinglyLinkedList(DragIcon).Node) catch {
            log.crit("out of memory", .{});
            return;
        };
        node.data.init(self, wlr_drag_icon);
        server.root.drag_icons.prepend(node);
    }
    self.cursor.mode = .passthrough;
}

fn handleRequestSetPrimarySelection(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection),
    event: *wlr.Seat.event.RequestSetPrimarySelection,
) void {
    const self = @fieldParentPtr(Self, "request_set_primary_selection", listener);
    self.wlr_seat.setPrimarySelection(event.source, event.serial);
}
