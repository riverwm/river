// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020-2024 The River Developers
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

const Seat = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;
const xkb = @import("xkbcommon");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Cursor = @import("Cursor.zig");
const DragIcon = @import("DragIcon.zig");
const InputDevice = @import("InputDevice.zig");
const InputManager = @import("InputManager.zig");
const InputRelay = @import("InputRelay.zig");
const Keyboard = @import("Keyboard.zig");
const KeyboardGroup = @import("KeyboardGroup.zig");
const LockSurface = @import("LockSurface.zig");
const Output = @import("Output.zig");
const PointerBinding = @import("PointerBinding.zig");
const PointerConstraint = @import("PointerConstraint.zig");
const Switch = @import("Switch.zig");
const Tablet = @import("Tablet.zig");
const Window = @import("Window.zig");
const XkbBinding = @import("XkbBinding.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");

const log = std.log.scoped(.input);

pub const Event = union(enum) {
    keyboard_key: struct {
        keyboard: *Keyboard,
        key: wlr.Keyboard.event.Key,
    },
    keyboard_modifiers: struct {
        keyboard: *Keyboard,
        modifiers: wlr.Keyboard.Modifiers,
    },

    pointer_motion_relative: wlr.Pointer.event.Motion,
    pointer_motion_absolute: wlr.Pointer.event.MotionAbsolute,
    pointer_button: wlr.Pointer.event.Button,
    pointer_axis: wlr.Pointer.event.Axis,
    pointer_frame: void,

    pointer_swipe_begin: wlr.Pointer.event.SwipeBegin,
    pointer_swipe_update: wlr.Pointer.event.SwipeUpdate,
    pointer_swipe_end: wlr.Pointer.event.SwipeEnd,

    pointer_pinch_begin: wlr.Pointer.event.PinchBegin,
    pointer_pinch_update: wlr.Pointer.event.PinchUpdate,
    pointer_pinch_end: wlr.Pointer.event.PinchEnd,
};

pub const WmState = struct {
    focus: WmFocus = .none,
    op: union(enum) {
        none,
        //TODO start_serial: ?u32,
        start_pointer,
        end,
    } = .none,
    // TODO confine region
    // TODO pointer warp
};

pub const WmFocus = union(enum) {
    none,
    window: *Window,
    // TODO shell_surface: *ShellSurface,
};

pub const Focus = union(enum) {
    window: *Window,
    override_redirect: if (build_options.xwayland) *XwaylandOverrideRedirect else noreturn,
    lock_surface: *LockSurface,
    none: void,

    pub fn surface(target: Focus) ?*wlr.Surface {
        return switch (target) {
            .window => |window| window.rootSurface(),
            .override_redirect => |override_redirect| override_redirect.xsurface.surface,
            .lock_surface => |lock_surface| lock_surface.wlr_lock_surface.surface,
            .none => null,
        };
    }
};

/// XXX experiment with different sizes here, consider making dynamic
/// XXX Clean out events for destroyed input devices
const EventQueue = std.fifo.LinearFifo(Event, .{ .Static = 1024 });

wlr_seat: *wlr.Seat,

link: wl.list.Link,

destroying: bool = false,

object: ?*river.SeatV1 = null,

event_queue: EventQueue = EventQueue.init(),

/// State to be sent to the window manager client in the next update sequence.
pending: struct {
    /// The window entered/hovered by the pointer, if any
    window: ?*Window = null,
    /// The window clicked on, touched, etc.
    window_interaction: ?*Window = null,
} = .{},

/// State sent to the window manager client in the latest update sequence.
sent: struct {
    /// The window entered/hovered by the pointer, if any
    window: ?*Window = null,
} = .{},
link_sent: wl.list.Link,

/// State requested by the window manager client but not yet committed.
uncommitted: WmState = .{},
/// State requested by the window manager client and committed.
committed: WmState = .{},

xkb_bindings: wl.list.Head(XkbBinding, .link),
pointer_bindings: wl.list.Head(PointerBinding, .link),

/// Multiple physical mice are handled by the same Cursor
cursor: Cursor,

op: ?struct {
    // We always want to process as many input events as possible before sending configures
    // and starting a transaction. Therefore, we set this flag if a seat operation modifies
    // pending state and check it at the end of Seat.processEvents() rather than calling
    // WindowManager.dirtyPending() directly in Seat.updateOp().
    dirty: bool = false,
    input: enum {
        pointer,
    },
    /// Coordinates of the cursor/touch point/etc. at the start of the operation.
    start_x: i32,
    start_y: i32,
} = null,

relay: InputRelay,

keyboard_groups: std.TailQueue(KeyboardGroup) = .{},

focused: Focus = .none,

/// The currently in progress drag operation type.
drag: enum {
    none,
    pointer,
    touch,
} = .none,

request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) =
    wl.Listener(*wlr.Seat.event.RequestSetSelection).init(handleRequestSetSelection),
request_start_drag: wl.Listener(*wlr.Seat.event.RequestStartDrag) =
    wl.Listener(*wlr.Seat.event.RequestStartDrag).init(handleRequestStartDrag),
start_drag: wl.Listener(*wlr.Drag) = wl.Listener(*wlr.Drag).init(handleStartDrag),
drag_destroy: wl.Listener(*wlr.Drag) = wl.Listener(*wlr.Drag).init(handleDragDestroy),
request_set_primary_selection: wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection) =
    wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection).init(handleRequestSetPrimarySelection),

pub fn create(name: [*:0]const u8) !void {
    const seat = try util.gpa.create(Seat);
    errdefer util.gpa.destroy(seat);

    seat.* = .{
        // This will be automatically destroyed when the display is destroyed
        .wlr_seat = try wlr.Seat.create(server.wl_server, name),
        .link = undefined,
        .link_sent = undefined,
        .xkb_bindings = undefined,
        .pointer_bindings = undefined,
        .cursor = undefined,
        .relay = undefined,
    };
    seat.wlr_seat.data = @intFromPtr(seat);

    server.input_manager.seats.append(seat);
    seat.link_sent.init();
    server.wm.dirtyPending();

    seat.xkb_bindings.init();
    seat.pointer_bindings.init();

    try seat.cursor.init(seat);
    seat.relay.init();

    seat.wlr_seat.events.request_set_selection.add(&seat.request_set_selection);
    seat.wlr_seat.events.request_start_drag.add(&seat.request_start_drag);
    seat.wlr_seat.events.start_drag.add(&seat.start_drag);
    seat.wlr_seat.events.request_set_primary_selection.add(&seat.request_set_primary_selection);
}

pub fn destroy(seat: *Seat) void {
    {
        var it = server.input_manager.devices.iterator(.forward);
        while (it.next()) |device| assert(device.seat != seat);
    }

    {
        // Remove pointers to the seat before they become dangling
        var it = server.wm.windows.iterator(.forward);
        while (it.next()) |window| {
            inline for (.{
                &window.uncommitted,
                &window.committed,
                &window.inflight,
                &window.current,
            }) |state| {
                switch (state.op) {
                    .none => {},
                    inline .move, .resize => |data| {
                        if (data.seat == seat) state.op = .none;
                    },
                }
            }
        }
    }

    seat.link.remove();
    seat.link_sent.remove();

    seat.cursor.deinit();

    while (seat.keyboard_groups.first) |node| {
        node.data.destroy();
    }

    seat.request_set_selection.link.remove();
    seat.request_start_drag.link.remove();
    seat.start_drag.link.remove();
    if (seat.drag != .none) seat.drag_destroy.link.remove();
    seat.request_set_primary_selection.link.remove();
}

pub fn queueEvent(seat: *Seat, event: Event) void {
    seat.handleActivity();

    seat.event_queue.writeItem(event) catch {
        log.err("dropping {s} event, no space in event queue", .{@tagName(event)});
        return;
    };

    if (server.wm.state == .idle) {
        seat.processEvents();
    }
}

pub fn processEvents(seat: *Seat) void {
    assert(server.wm.state == .idle);

    // Only process events while there is no pending state to be sent to the window manager.
    // The window manager might decide to change focus or redefine keyboard/pointer bindings
    // in response to the pending update.
    while (!server.wm.pending.dirty) {
        const event = seat.event_queue.readItem() orelse break;

        const pg = server.input_manager.pointer_gestures;
        switch (event) {
            .keyboard_key => |ev| ev.keyboard.processKey(&ev.key),
            .keyboard_modifiers => |ev| ev.keyboard.processModifiers(&ev.modifiers),

            .pointer_motion_relative => |ev| seat.cursor.processMotionRelative(&ev),
            .pointer_motion_absolute => |ev| seat.cursor.processMotionAbsolute(&ev),
            .pointer_button => |ev| seat.cursor.processButton(&ev),
            .pointer_axis => |ev| seat.cursor.processAxis(&ev),
            .pointer_frame => seat.wlr_seat.pointerNotifyFrame(),

            .pointer_swipe_begin => |ev| pg.sendSwipeBegin(seat.wlr_seat, ev.time_msec, ev.fingers),
            .pointer_swipe_update => |ev| pg.sendSwipeUpdate(seat.wlr_seat, ev.time_msec, ev.dx, ev.dy),
            .pointer_swipe_end => |ev| pg.sendSwipeEnd(seat.wlr_seat, ev.time_msec, ev.cancelled),

            .pointer_pinch_begin => |ev| pg.sendPinchBegin(seat.wlr_seat, ev.time_msec, ev.fingers),
            .pointer_pinch_update => |ev| pg.sendPinchUpdate(seat.wlr_seat, ev.time_msec, ev.dx, ev.dy, ev.scale, ev.rotation),
            .pointer_pinch_end => |ev| pg.sendPinchEnd(seat.wlr_seat, ev.time_msec, ev.cancelled),
        }
    }

    if (seat.op) |*op| {
        if (op.dirty) {
            server.wm.dirtyPending();
            op.dirty = false;
        }
    }
}

pub fn sendDirty(seat: *Seat) void {
    if (seat.destroying) {
        if (seat.object) |seat_v1| {
            seat_v1.sendRemoved();
            seat_v1.setHandler(?*anyopaque, handleRequestInert, null, null);
            seat.object = null;
        }
        seat.destroy();
        return;
    }

    if (server.wm.object) |wm_v1| {
        const new = seat.object == null;
        const seat_v1 = seat.object orelse blk: {
            const seat_v1 = river.SeatV1.create(wm_v1.getClient(), wm_v1.getVersion(), 0) catch {
                log.err("out of memory", .{});
                return; // try again next update
            };
            seat.object = seat_v1;

            seat_v1.setHandler(*Seat, handleRequest, handleDestroy, seat);
            wm_v1.sendSeat(seat_v1);

            seat.link_sent.remove();
            server.wm.sent.seats.append(seat);

            break :blk seat_v1;
        };
        errdefer comptime unreachable;

        if (new) {
            if (seat.pending.window) |window| {
                if (window.object) |window_v1| {
                    seat_v1.sendPointerEnter(window_v1);
                    seat.sent.window = seat.pending.window;
                }
            }
        } else if (seat.pending.window != seat.sent.window) {
            if (seat.sent.window) |window| {
                if (window.object) |window_v1| {
                    seat_v1.sendPointerLeave(window_v1);
                    seat.sent.window = null;
                }
            }
            if (seat.pending.window) |window| {
                if (window.object) |window_v1| {
                    seat_v1.sendPointerEnter(window_v1);
                    seat.sent.window = window;
                }
            }
        }

        if (seat.pending.window_interaction) |window| {
            if (window.object) |window_v1| {
                seat_v1.sendWindowInteraction(window_v1);
                seat.pending.window_interaction = null;
            }
        }

        {
            var it = seat.xkb_bindings.iterator(.forward);
            while (it.next()) |binding| {
                switch (binding.pending.state_change) {
                    .none => {},
                    .pressed => {
                        assert(!binding.sent_pressed);
                        binding.sent_pressed = true;
                        binding.object.sendPressed();
                    },
                    .released => {
                        assert(binding.sent_pressed);
                        binding.sent_pressed = false;
                        binding.object.sendReleased();
                    },
                }
                binding.pending.state_change = .none;
            }
        }
        {
            var it = seat.pointer_bindings.iterator(.forward);
            while (it.next()) |binding| {
                switch (binding.pending.state_change) {
                    .none => {},
                    .pressed => {
                        assert(!binding.sent_pressed);
                        binding.sent_pressed = true;
                        binding.object.sendPressed();
                    },
                    .released => {
                        assert(binding.sent_pressed);
                        binding.sent_pressed = false;
                        binding.object.sendReleased();
                    },
                }
                binding.pending.state_change = .none;
            }
        }
    }
}

fn handleRequestInert(
    seat_v1: *river.SeatV1,
    request: river.SeatV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) seat_v1.destroy();
}

fn handleDestroy(_: *river.SeatV1, seat: *Seat) void {
    seat.object = null;
}

fn handleRequest(
    seat_v1: *river.SeatV1,
    request: river.SeatV1.Request,
    seat: *Seat,
) void {
    assert(seat.object == seat_v1);
    switch (request) {
        .destroy => {
            // XXX send protocol error
            seat_v1.destroy();
        },

        .focus_window => |args| {
            const data = args.window.getUserData() orelse return;
            const window: *Window = @ptrCast(@alignCast(data));
            seat.uncommitted.focus = .{ .window = window };
        },
        .focus_shell_surface => {},
        .clear_focus => seat.uncommitted.focus = .none,

        .op_start_serial => {},
        .op_start_pointer => seat.uncommitted.op = .start_pointer,
        .op_add_move_window => |args| {
            const data = args.window.getUserData() orelse return;
            const window: *Window = @ptrCast(@alignCast(data));
            window.uncommitted.op = .{ .move = .{
                .seat = seat,
            } };
        },
        .op_add_resize_window => |args| {
            const data = args.window.getUserData() orelse return;
            const window: *Window = @ptrCast(@alignCast(data));
            window.uncommitted.op = .{ .resize = .{
                .seat = seat,
                .edges = args.edges,
            } };
        },
        .op_end => seat.uncommitted.op = .end,

        .pointer_confine_to_region => {},
        .pointer_warp => {},

        .get_xkb_binding => |args| {
            XkbBinding.create(
                seat,
                seat_v1.getClient(),
                seat_v1.getVersion(),
                args.id,
                @enumFromInt(args.keysym),
                args.modifiers,
            ) catch {
                seat_v1.getClient().postNoMemory();
                log.err("out of memory", .{});
                return;
            };
        },
        .get_pointer_binding => |args| {
            PointerBinding.create(
                seat,
                seat_v1.getClient(),
                seat_v1.getVersion(),
                args.id,
                args.button,
                args.modifiers,
            ) catch {
                seat_v1.getClient().postNoMemory();
                log.err("out of memory", .{});
                return;
            };
        },
    }
}

pub fn commitWmState(seat: *Seat) void {
    {
        var it = seat.xkb_bindings.iterator(.forward);
        while (it.next()) |binding| {
            binding.committed = binding.uncommitted;
        }
    }
    {
        var it = seat.pointer_bindings.iterator(.forward);
        while (it.next()) |binding| {
            binding.committed = binding.uncommitted;
        }
    }

    seat.committed = seat.uncommitted;
    seat.uncommitted.op = .none;
}

pub fn applyCommitted(seat: *Seat) void {
    if (server.lock_manager.state != .unlocked) return;

    switch (seat.committed.focus) {
        .none => seat.focus(.none),
        .window => |window| seat.focus(.{ .window = window }),
    }

    switch (seat.committed.op) {
        .none => {},
        .start_pointer => if (seat.op == null) {
            log.debug("start seat op pointer", .{});
            seat.op = .{
                .input = .pointer,
                .start_x = @intFromFloat(seat.cursor.wlr_cursor.x),
                .start_y = @intFromFloat(seat.cursor.wlr_cursor.y),
            };
            seat.cursor.startOpPointer();

            {
                var it = server.wm.windows.iterator(.forward);
                while (it.next()) |window| {
                    switch (window.committed.op) {
                        .none => {},
                        .move => |data| {
                            if (data.seat == seat) {
                                assert(window.inflight.op == .none);
                                window.inflight.op = .{
                                    .move = .{
                                        .seat = seat,
                                        .start_x = window.pending.box.x,
                                        .start_y = window.pending.box.y,
                                    },
                                };
                            }
                        },
                        .resize => |data| {
                            if (data.seat == seat) {
                                assert(window.inflight.op == .none);
                                window.inflight.op = .{
                                    .resize = .{
                                        .seat = seat,
                                        .edges = data.edges,
                                        .start_box = window.pending.box,
                                    },
                                };
                            }
                        },
                    }
                }
            }
        },
        .end => if (seat.op) |op| {
            log.debug("end seat op", .{});
            seat.op = null;
            switch (op.input) {
                .pointer => seat.cursor.endOpPointer(),
            }

            {
                var it = server.wm.windows.iterator(.forward);
                while (it.next()) |window| {
                    switch (window.inflight.op) {
                        .none => {},
                        inline .move, .resize => |data| {
                            if (data.seat == seat) {
                                window.inflight.op = .none;
                            }
                        },
                    }
                }
            }
        },
    }
}

pub fn focus(seat: *Seat, new_focus: Focus) void {
    // If the target is already focused, do nothing
    if (std.meta.eql(new_focus, seat.focused)) return;

    const target_surface = new_focus.surface();

    // First clear the current focus
    switch (seat.focused) {
        .window => |window| window.destroyPopups(),
        .override_redirect, .lock_surface, .none => {},
    }

    // Set the new focus
    switch (new_focus) {
        .window => assert(server.lock_manager.state != .locked),
        .lock_surface => assert(server.lock_manager.state != .unlocked),
        .override_redirect, .none => {},
    }
    seat.focused = new_focus;

    if (seat.cursor.constraint) |constraint| {
        if (constraint.wlr_constraint.surface != target_surface) {
            if (constraint.state == .active) {
                log.info("deactivating pointer constraint for surface, keyboard focus lost", .{});
                constraint.deactivate();
            }
            seat.cursor.constraint = null;
        }
    }

    seat.keyboardEnterOrLeave(target_surface);
    seat.relay.focus(target_surface);

    if (target_surface) |surface| {
        const pointer_constraints = server.input_manager.pointer_constraints;
        if (pointer_constraints.constraintForSurface(surface, seat.wlr_seat)) |wlr_constraint| {
            if (seat.cursor.constraint) |constraint| {
                assert(constraint.wlr_constraint == wlr_constraint);
            } else {
                seat.cursor.constraint = @ptrFromInt(wlr_constraint.data);
                assert(seat.cursor.constraint != null);
            }
        }
    }
}

/// Send keyboard enter/leave events and handle pointer constraints
/// This should never normally be called from outside of setFocusRaw(), but we make an exception for
/// XwaylandOverrideRedirect surfaces as they don't conform to the Wayland focus model.
pub fn keyboardEnterOrLeave(seat: *Seat, target_surface: ?*wlr.Surface) void {
    if (target_surface) |wlr_surface| {
        seat.keyboardNotifyEnter(wlr_surface);
    } else {
        seat.wlr_seat.keyboardNotifyClearFocus();
    }
}

fn keyboardNotifyEnter(seat: *Seat, wlr_surface: *wlr.Surface) void {
    if (seat.wlr_seat.getKeyboard()) |wlr_keyboard| {
        const keyboard: *Keyboard = @ptrFromInt(wlr_keyboard.data);

        var keycodes: std.BoundedArray(u32, Keyboard.Pressed.capacity) = .{};
        for (keyboard.pressed.keys.constSlice()) |item| {
            if (item.consumer == .focus) keycodes.appendAssumeCapacity(item.code);
        }

        seat.wlr_seat.keyboardNotifyEnter(
            wlr_surface,
            keycodes.constSlice(),
            // XXX this is not ok, use our own stored modifiers
            &wlr_keyboard.modifiers,
        );
    } else {
        seat.wlr_seat.keyboardNotifyEnter(wlr_surface, &.{}, null);
    }
}

pub fn handleActivity(seat: Seat) void {
    server.input_manager.idle_notifier.notifyActivity(seat.wlr_seat);
}

/// Handle any user-defined mapping for passed keycode, modifiers and keyboard state
/// Returns true if a mapping was run
pub fn matchXkbBinding(
    seat: *Seat,
    keycode: xkb.Keycode,
    modifiers: wlr.Keyboard.ModifierMask,
    xkb_state: *xkb.State,
) ?*XkbBinding {
    // It is possible for more than one binding to be matched due to the
    // existence of layout-independent bindings. It is also possible due to
    // translation by xkbcommon consuming modifiers. On the swedish layout
    // for example, translating Super+Shift+Space may consume the Shift
    // modifier and confict with a binding for Super+Space. For this reason,
    // matching wihout xkbcommon translation is done first and after a match
    // has been found all further matches are ignored.
    var found: ?*XkbBinding = null;

    // First check for matches without translating keysyms with xkbcommon.
    // That is, if the physical keys Mod+Shift+1 are pressed on a US layout don't
    // translate the keysym 1 to an exclamation mark. This behavior is generally
    // what is desired.
    {
        var it = seat.xkb_bindings.iterator(.forward);
        while (it.next()) |binding| {
            if (binding.match(keycode, modifiers, xkb_state, .no_translate)) {
                if (found == null) {
                    found = binding;
                } else {
                    log.debug("already found a matching xkb_binding, ignoring additional match", .{});
                }
            }
        }
    }

    // There are however some cases where it is necessary to translate keysyms
    // with xkbcommon for intuitive behavior. For example, layouts may require
    // translation with the numlock modifier to obtain keypad number keysyms
    // (e.g. KP_1).
    {
        var it = seat.xkb_bindings.iterator(.forward);
        while (it.next()) |binding| {
            if (binding.match(keycode, modifiers, xkb_state, .translate)) {
                if (found == null) {
                    found = binding;
                } else {
                    log.debug("already found a matching xkb_binding, ignoring additional match", .{});
                }
            }
        }
    }

    return found;
}

pub fn matchPointerBinding(
    seat: *Seat,
    button: u32,
) ?*PointerBinding {
    const wlr_keyboard = seat.wlr_seat.getKeyboard() orelse return null;
    // XXX this is not ok, we need to store current modifiers per-Keyboard ourselves
    const modifiers = wlr_keyboard.getModifiers();

    var found: ?*PointerBinding = null;
    {
        var it = seat.pointer_bindings.iterator(.forward);
        while (it.next()) |binding| {
            if (binding.match(button, modifiers)) {
                if (found == null) {
                    found = binding;
                } else {
                    log.debug("already found a matching pointer binding, ignoring additional match", .{});
                }
            }
        }
    }

    return found;
}

/// Handle any user-defined mapping for switches
pub fn handleSwitchMapping(
    _: *Seat,
    switch_type: Switch.Type,
    switch_state: Switch.State,
) void {
    for (server.config.switch_mappings.items) |mapping| {
        if (std.meta.eql(mapping.switch_type, switch_type) and std.meta.eql(mapping.switch_state, switch_state)) {
            // send trigger
        }
    }
}

pub fn updateOp(seat: *Seat, x: i32, y: i32) void {
    const op = seat.op.?;

    // Total dx/dy since operation start
    const dx = x - op.start_x;
    const dy = y - op.start_y;

    {
        var it = server.wm.windows.iterator(.forward);
        while (it.next()) |window| {
            switch (window.inflight.op) {
                .none => {},
                .move => |data| {
                    if (data.seat != seat) continue;

                    window.pending.box.x = data.start_x + dx;
                    window.pending.box.y = data.start_y + dy;

                    seat.op.?.dirty = true;
                },
                .resize => |data| {
                    if (data.seat != seat) continue;

                    // For resize, position is not updated until the window has committed
                    // its new dimensions. The client may not commit exactly the dimensions
                    // we request and we need to know the actual committed dimensions to
                    // correctly place the top left corner in the case of a resize from
                    // the top or left edge.
                    if (data.edges.left) {
                        window.pending.box.width = @max(1, data.start_box.width - dx);
                    } else if (data.edges.right) {
                        window.pending.box.width = @max(1, data.start_box.width + dx);
                    }

                    if (data.edges.top) {
                        window.pending.box.height = @max(1, data.start_box.height - dy);
                    } else if (data.edges.bottom) {
                        window.pending.box.height = @max(1, data.start_box.height + dy);
                    }

                    seat.op.?.dirty = true;
                },
            }
        }
    }
}

pub fn addDevice(seat: *Seat, wlr_device: *wlr.InputDevice) void {
    seat.tryAddDevice(wlr_device) catch |err| switch (err) {
        error.OutOfMemory => log.err("out of memory", .{}),
    };
}

fn tryAddDevice(seat: *Seat, wlr_device: *wlr.InputDevice) !void {
    switch (wlr_device.type) {
        .keyboard => {
            const keyboard = try util.gpa.create(Keyboard);
            errdefer util.gpa.destroy(keyboard);

            try keyboard.init(seat, wlr_device);

            seat.wlr_seat.setKeyboard(keyboard.device.wlr_device.toKeyboard());
            if (seat.wlr_seat.keyboard_state.focused_surface) |wlr_surface| {
                seat.keyboardNotifyEnter(wlr_surface);
            }
        },
        .pointer, .touch => {
            const device = try util.gpa.create(InputDevice);
            errdefer util.gpa.destroy(device);

            try device.init(seat, wlr_device);

            seat.cursor.wlr_cursor.attachInputDevice(wlr_device);
        },
        .tablet => {
            try Tablet.create(seat, wlr_device);
            seat.cursor.wlr_cursor.attachInputDevice(wlr_device);
        },
        .@"switch" => {
            const switch_device = try util.gpa.create(Switch);
            errdefer util.gpa.destroy(switch_device);

            try switch_device.init(seat, wlr_device);
        },

        // TODO Support these types of input devices.
        .tablet_pad => {},
    }
}

pub fn updateCapabilities(seat: *Seat) void {
    // Currently a cursor is always drawn even if there are no pointer input devices.
    // TODO Don't draw a cursor if there are no input devices.
    var capabilities: wl.Seat.Capability = .{ .pointer = true };

    var it = server.input_manager.devices.iterator(.forward);
    while (it.next()) |device| {
        if (device.seat == seat) {
            switch (device.wlr_device.type) {
                .keyboard => capabilities.keyboard = true,
                .touch => capabilities.touch = true,
                .pointer, .@"switch", .tablet => {},
                .tablet_pad => unreachable,
            }
        }
    }

    seat.wlr_seat.setCapabilities(capabilities);
}

fn handleRequestSetSelection(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
    event: *wlr.Seat.event.RequestSetSelection,
) void {
    const seat: *Seat = @fieldParentPtr("request_set_selection", listener);
    seat.wlr_seat.setSelection(event.source, event.serial);
}

fn handleRequestStartDrag(
    listener: *wl.Listener(*wlr.Seat.event.RequestStartDrag),
    event: *wlr.Seat.event.RequestStartDrag,
) void {
    const seat: *Seat = @fieldParentPtr("request_start_drag", listener);

    // The start_drag request is ignored by wlroots if a drag is currently in progress.
    assert(seat.drag == .none);

    if (seat.wlr_seat.validatePointerGrabSerial(event.origin, event.serial)) {
        log.debug("starting pointer drag", .{});
        seat.wlr_seat.startPointerDrag(event.drag, event.serial);
        return;
    }

    var point: *wlr.TouchPoint = undefined;
    if (seat.wlr_seat.validateTouchGrabSerial(event.origin, event.serial, &point)) {
        log.debug("starting touch drag", .{});
        seat.wlr_seat.startTouchDrag(event.drag, event.serial, point);
        return;
    }

    log.debug("ignoring request to start drag, " ++
        "failed to validate pointer or touch serial {}", .{event.serial});
    if (event.drag.source) |source| source.destroy();
}

fn handleStartDrag(listener: *wl.Listener(*wlr.Drag), wlr_drag: *wlr.Drag) void {
    const seat: *Seat = @fieldParentPtr("start_drag", listener);

    assert(seat.drag == .none);
    switch (wlr_drag.grab_type) {
        .keyboard_pointer => {
            seat.drag = .pointer;
            seat.cursor.mode = .passthrough;
        },
        .keyboard_touch => seat.drag = .touch,
        .keyboard => unreachable,
    }
    wlr_drag.events.destroy.add(&seat.drag_destroy);

    if (wlr_drag.icon) |wlr_drag_icon| {
        DragIcon.create(wlr_drag_icon, &seat.cursor) catch {
            log.err("out of memory", .{});
            wlr_drag.seat_client.client.postNoMemory();
            return;
        };
    }
}

fn handleDragDestroy(listener: *wl.Listener(*wlr.Drag), _: *wlr.Drag) void {
    const seat: *Seat = @fieldParentPtr("drag_destroy", listener);
    seat.drag_destroy.link.remove();

    switch (seat.drag) {
        .none => unreachable,
        .pointer => {
            seat.cursor.updateState();
        },
        .touch => {},
    }
    seat.drag = .none;
}

fn handleRequestSetPrimarySelection(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection),
    event: *wlr.Seat.event.RequestSetPrimarySelection,
) void {
    const seat: *Seat = @fieldParentPtr("request_set_primary_selection", listener);
    seat.wlr_seat.setPrimarySelection(event.source, event.serial);
}
