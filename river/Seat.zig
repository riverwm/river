// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const Seat = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;
const xkb = @import("xkbcommon");
const Deque = @import("deque").Deque;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Cursor = @import("Cursor.zig");
const DragIcon = @import("DragIcon.zig");
const InputDevice = @import("InputDevice.zig");
const InputManager = @import("InputManager.zig");
const InputRelay = @import("InputRelay.zig");
const Keyboard = @import("Keyboard.zig");
const KeyboardGroup = @import("KeyboardGroup.zig");
const LayerShellSeat = @import("LayerShellSeat.zig");
const LayerSurface = @import("LayerSurface.zig");
const LockSurface = @import("LockSurface.zig");
const Output = @import("Output.zig");
const PointerBinding = @import("PointerBinding.zig");
const PointerConstraint = @import("PointerConstraint.zig");
const ShellSurface = @import("ShellSurface.zig");
const Tablet = @import("Tablet.zig");
const Window = @import("Window.zig");
const XkbBinding = @import("XkbBinding.zig");
const XkbBindingsSeat = @import("XkbBindingsSeat.zig");
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
    /// This event is really just for virtual keyboards, which set their own keymaps.
    keyboard_keymap: struct {
        keyboard: *Keyboard,
        keymap: *xkb.Keymap,
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

pub const Focus = union(enum) {
    none,
    window: *Window,
    shell_surface: *ShellSurface,
    override_redirect: if (build_options.xwayland) *XwaylandOverrideRedirect else noreturn,
    lock_surface: *LockSurface,
    layer_surface: *LayerSurface,

    pub fn surface(target: Focus) ?*wlr.Surface {
        return switch (target) {
            .window => |window| window.rootSurface(),
            .shell_surface => |shell_surface| shell_surface.surface,
            .override_redirect => |override_redirect| override_redirect.xsurface.surface,
            .lock_surface => |lock_surface| lock_surface.wlr_lock_surface.surface,
            .layer_surface => |layer_surface| layer_surface.wlr_layer_surface.surface,
            .none => null,
        };
    }
};

wlr_seat: *wlr.Seat,

link: wl.list.Link,

destroying: bool = false,

object: ?*river.SeatV1 = null,
layer_shell: LayerShellSeat = .{},
xkb_bindings_seat: XkbBindingsSeat = .{},

event_queue: Deque(Event),

/// State to be sent to the wm in the next manage sequence.
wm_scheduled: struct {
    /// The window entered/hovered by the pointer, if any
    hovered: ?Window.Ref = null,
    /// The window clicked on, touched, etc.
    interaction: union(enum) {
        none,
        window: Window.Ref,
        shell_surface: *ShellSurface,
    } = .none,
    op_release: bool = false,
} = .{},

/// State sent to the wm in the latest manage sequence.
wm_sent: struct {
    /// The window entered/hovered by the pointer, if any
    hovered: ?Window.Ref = null,
    x: i32 = 0,
    y: i32 = 0,
} = .{},
link_sent: wl.list.Link,

/// Windowing state requested by the wm.
wm_requested: struct {
    focus: union(enum) {
        none,
        clear,
        window: Window.Ref,
        shell_surface: *ShellSurface,
    } = .none,
    op: union(enum) {
        none,
        start_pointer,
        end,
    } = .none,
    pointer_warp: ?struct { x: i32, y: i32 } = null,
} = .{},

xkb_bindings: wl.list.Head(XkbBinding, .link),
pointer_bindings: wl.list.Head(PointerBinding, .link),

/// Multiple physical mice are handled by the same Cursor
cursor: Cursor,

op: ?struct {
    dirty: bool = false,
    sent_release: bool = false,
    input: enum {
        pointer,
    },
    /// Coordinates of the cursor/touch point/etc. at the start of the operation.
    start_x: i32,
    start_y: i32,
    x: i32,
    y: i32,
} = null,

relay: InputRelay,

keyboard_groups: wl.list.Head(KeyboardGroup, .link),

focused: Focus = .none,

/// The currently in progress drag operation type.
drag: enum {
    none,
    pointer,
    touch,
} = .none,

request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(handleRequestSetSelection),
request_start_drag: wl.Listener(*wlr.Seat.event.RequestStartDrag) = .init(handleRequestStartDrag),
start_drag: wl.Listener(*wlr.Drag) = .init(handleStartDrag),
drag_destroy: wl.Listener(*wlr.Drag) = .init(handleDragDestroy),
request_set_primary_selection: wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection) = .init(handleRequestSetPrimarySelection),

pub fn create(name: [*:0]const u8) !void {
    const seat = try util.gpa.create(Seat);
    errdefer util.gpa.destroy(seat);

    // Empirically, this limit is not hit in practice unless the window manager hangs.
    // TODO have better reasoning for choosing this capacity.
    var event_queue: Deque(Event) = try .initCapacity(util.gpa, 1024);
    errdefer event_queue.deinit(util.gpa);

    seat.* = .{
        .wlr_seat = try wlr.Seat.create(server.wl_server, name),
        .event_queue = event_queue,
        .link = undefined,
        .link_sent = undefined,
        .xkb_bindings = undefined,
        .pointer_bindings = undefined,
        .cursor = undefined,
        .relay = undefined,
        .keyboard_groups = undefined,
    };
    seat.wlr_seat.data = seat;

    server.input_manager.seats.append(seat);
    seat.link_sent.init();
    server.wm.dirtyWindowing();

    seat.xkb_bindings.init();
    seat.pointer_bindings.init();

    try seat.cursor.init(seat);
    seat.relay.init();

    seat.keyboard_groups.init();

    seat.wlr_seat.events.request_set_selection.add(&seat.request_set_selection);
    seat.wlr_seat.events.request_start_drag.add(&seat.request_start_drag);
    seat.wlr_seat.events.start_drag.add(&seat.start_drag);
    seat.wlr_seat.events.request_set_primary_selection.add(&seat.request_set_primary_selection);
}

pub fn destroy(seat: *Seat) void {
    while (seat.event_queue.popFront()) |event| {
        switch (event) {
            .keyboard_key => |data| data.keyboard.dropEvent(),
            .keyboard_modifiers => |data| data.keyboard.dropEvent(),
            .keyboard_keymap => |data| {
                data.keyboard.dropEvent();
                data.keymap.unref();
            },
            .pointer_motion_relative,
            .pointer_motion_absolute,
            .pointer_button,
            .pointer_axis,
            .pointer_frame,
            .pointer_swipe_begin,
            .pointer_swipe_update,
            .pointer_swipe_end,
            .pointer_pinch_begin,
            .pointer_pinch_update,
            .pointer_pinch_end,
            => {},
        }
    }
    {
        var it = server.input_manager.devices.iterator(.forward);
        while (it.next()) |device| {
            if (device.seat == seat) {
                device.assignToSeat(server.input_manager.defaultSeat());
            }
        }
    }
    {
        var it = server.input_manager.devices.iterator(.forward);
        while (it.next()) |device| assert(device.seat != seat);
    }
    assert(seat.keyboard_groups.empty());

    while (seat.xkb_bindings.first()) |binding| binding.destroy();
    while (seat.pointer_bindings.first()) |binding| binding.destroy();

    seat.link.remove();
    seat.link_sent.remove();

    seat.event_queue.deinit(util.gpa);
    seat.cursor.deinit();

    seat.request_set_selection.link.remove();
    seat.request_start_drag.link.remove();
    seat.start_drag.link.remove();
    if (seat.drag != .none) seat.drag_destroy.link.remove();
    seat.request_set_primary_selection.link.remove();

    seat.wlr_seat.destroy();
}

pub fn queueEvent(seat: *Seat, event: Event) !void {
    seat.handleActivity();

    seat.event_queue.pushBackBounded(event) catch {
        log.err("dropping {s} event, no space in event queue", .{@tagName(event)});
        return error.QueueFull;
    };

    if (server.wm.state == .idle) {
        seat.processEvents();
    }
}

pub fn processEvents(seat: *Seat) void {
    assert(server.wm.state == .idle);

    // Only process events while there is no new state to be sent to the window manager.
    // The window manager might decide to change focus or redefine keyboard/pointer bindings
    // in response, which can affect further processing of events.
    while (!server.wm.scheduled.dirty) {
        assert(server.wm.state == .idle);

        const event = seat.event_queue.popFront() orelse break;

        const pg = server.input_manager.pointer_gestures;
        switch (event) {
            .keyboard_key => |ev| ev.keyboard.processKey(&ev.key),
            .keyboard_modifiers => |ev| ev.keyboard.processModifiers(ev.modifiers),
            .keyboard_keymap => |ev| ev.keyboard.processKeymap(ev.keymap),

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
    assert(server.wm.state == .idle);

    if (seat.op) |*op| {
        if (op.dirty) {
            op.dirty = false;
            server.wm.dirtyWindowing();
        }
    }
}

pub fn manageStart(seat: *Seat) void {
    if (seat.destroying) {
        if (seat.object) |seat_v1| {
            seat_v1.sendRemoved();
            seat_v1.setHandler(?*anyopaque, handleRequestInert, null, null);
            seat.layer_shell.makeInert();
            seat.xkb_bindings_seat.makeInert();
            seat.object = null;
        }
        seat.destroy();
        return;
    }

    seat.layer_shell.manageStart();
    seat.xkb_bindings_seat.manageStart();

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
            seat_v1.sendWlSeat(seat.wlr_seat.global.getName(seat_v1.getClient()));
        }

        if (new) {
            if (seat.wm_scheduled.hovered) |ref| {
                if (ref.get()) |window| {
                    if (window.object) |window_v1| {
                        seat_v1.sendPointerEnter(window_v1);
                        seat.wm_sent.hovered = seat.wm_scheduled.hovered;
                    }
                }
            }
        } else if (seat.wm_scheduled.hovered != seat.wm_sent.hovered) {
            if (seat.wm_sent.hovered != null) {
                seat_v1.sendPointerLeave();
                seat.wm_sent.hovered = null;
            }
            if (seat.wm_scheduled.hovered) |ref| {
                if (ref.get()) |window| {
                    if (window.object) |window_v1| {
                        seat_v1.sendPointerEnter(window_v1);
                        seat.wm_sent.hovered = seat.wm_scheduled.hovered;
                    }
                }
            }
        }

        {
            const x = math.lossyCast(i32, seat.cursor.wlr_cursor.x);
            const y = math.lossyCast(i32, seat.cursor.wlr_cursor.y);
            if (new or x != seat.wm_sent.x or y != seat.wm_sent.y) {
                if (seat_v1.getVersion() >= 2) {
                    seat_v1.sendPointerPosition(x, y);
                }
            }
        }

        switch (seat.wm_scheduled.interaction) {
            .none => {},
            .window => |ref| {
                if (ref.get()) |window| {
                    if (window.object) |window_v1| {
                        seat_v1.sendWindowInteraction(window_v1);
                    }
                }
            },
            .shell_surface => |shell_surface| {
                seat_v1.sendShellSurfaceInteraction(shell_surface.object);
            },
        }

        if (seat.op) |*op| {
            seat_v1.sendOpDelta(op.x - op.start_x, op.y - op.start_y);

            if (seat.wm_scheduled.op_release and !op.sent_release) {
                seat_v1.sendOpRelease();
                seat.wm_scheduled.op_release = false;
                op.sent_release = true;
            }
        }

        {
            var it = seat.xkb_bindings.iterator(.forward);
            while (it.next()) |binding| {
                switch (binding.wm_scheduled.state_change) {
                    .none => {},
                    .pressed => {
                        assert(!binding.sent_pressed);
                        binding.sent_pressed = true;
                        binding.object.sendPressed();
                    },
                    .stop_repeat => {
                        assert(binding.sent_pressed);
                        if (binding.object.getVersion() >= 2) {
                            binding.object.sendStopRepeat();
                        }
                    },
                    .released => {
                        assert(binding.sent_pressed);
                        binding.sent_pressed = false;
                        binding.object.sendReleased();
                    },
                }
                binding.wm_scheduled.state_change = .none;
            }
        }
        {
            var it = seat.pointer_bindings.iterator(.forward);
            while (it.next()) |binding| {
                switch (binding.wm_scheduled.state_change) {
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
                binding.wm_scheduled.state_change = .none;
            }
        }
    }
    // Ensure we don't store an interaction that happens while no window manager
    // is connected until a new window manager connects.
    seat.wm_scheduled.interaction = .none;
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
    seat.opEnd();
}

fn handleRequest(
    seat_v1: *river.SeatV1,
    request: river.SeatV1.Request,
    seat: *Seat,
) void {
    assert(seat.object == seat_v1);
    switch (request) {
        .destroy => {
            seat_v1.destroy();
        },
        .focus_window => |args| {
            if (!server.wm.ensureWindowing()) return;
            const data = args.window.getUserData() orelse return;
            const window: *Window = @ptrCast(@alignCast(data));
            seat.wm_requested.focus = .{ .window = window.ref };
        },
        .focus_shell_surface => |args| {
            if (!server.wm.ensureWindowing()) return;
            const data = args.shell_surface.getUserData() orelse return;
            const shell_surface: *ShellSurface = @ptrCast(@alignCast(data));
            seat.wm_requested.focus = .{ .shell_surface = shell_surface };
        },
        .clear_focus => seat.wm_requested.focus = .clear,

        .op_start_pointer => {
            if (!server.wm.ensureWindowing()) return;
            seat.wm_requested.op = .start_pointer;
        },
        .op_end => {
            if (!server.wm.ensureWindowing()) return;
            seat.wm_requested.op = .end;
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
        .set_xcursor_theme => |args| {
            seat.cursor.setTheme(args.name, args.size) catch |err| switch (err) {
                error.OutOfMemory => {
                    seat_v1.getClient().postNoMemory();
                    log.err("out of memory", .{});
                    return;
                },
            };
        },
        .pointer_warp => |args| {
            if (!server.wm.ensureWindowing()) return;
            seat.wm_requested.pointer_warp = .{ .x = args.x, .y = args.y };
        },
    }
}

pub fn manageFinish(seat: *Seat) void {
    seat.xkb_bindings_seat.manageFinish();

    if (server.lock_manager.state != .unlocked) return;

    switch (seat.layer_shell.sent.focus) {
        .exclusive => |ref| if (ref.get()) |layer_surface| {
            seat.focus(.{ .layer_surface = layer_surface });
        },
        .non_exclusive, .none => switch (seat.wm_requested.focus) {
            .none => switch (seat.layer_shell.sent.focus) {
                .exclusive => unreachable,
                .non_exclusive => |ref| if (ref.get()) |layer_surface| {
                    seat.focus(.{ .layer_surface = layer_surface });
                    seat.layer_shell.sent.focus = .none;
                },
                .none => {},
            },
            .clear => {
                seat.focus(.none);
            },
            .window => |ref| if (ref.get()) |window| {
                seat.focus(.{ .window = window });
            },
            .shell_surface => |shell_surface| {
                seat.focus(.{ .shell_surface = shell_surface });
            },
        },
    }
    seat.wm_requested.focus = .none;

    switch (seat.wm_requested.op) {
        .none => {},
        .start_pointer,
        => if (seat.op == null) {
            log.debug("start seat op pointer", .{});
            seat.op = .{
                .input = .pointer,
                .start_x = @intFromFloat(seat.cursor.wlr_cursor.x),
                .start_y = @intFromFloat(seat.cursor.wlr_cursor.y),
                .x = @intFromFloat(seat.cursor.wlr_cursor.x),
                .y = @intFromFloat(seat.cursor.wlr_cursor.y),
            };
            seat.cursor.opStartPointer();
        },
        .end => seat.opEnd(),
    }
    seat.wm_requested.op = .none;

    if (seat.wm_requested.pointer_warp) |target| {
        seat.wm_requested.pointer_warp = null;
        seat.cursor.wlr_cursor.warpClosest(null, @floatFromInt(target.x), @floatFromInt(target.y));
        seat.cursor.updateState();
    }
}

pub fn focus(seat: *Seat, new_focus: Focus) void {
    // If the target is already focused, do nothing
    if (std.meta.eql(new_focus, seat.focused)) return;

    const target_surface = new_focus.surface();

    // First clear the current focus
    switch (seat.focused) {
        .window => |window| window.destroyPopups(),
        .layer_surface => |layer_surface| layer_surface.destroyPopups(),
        .shell_surface, .override_redirect, .lock_surface, .none => {},
    }

    // Set the new focus
    switch (new_focus) {
        .window, .shell_surface, .layer_surface => assert(server.lock_manager.state != .locked),
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
                seat.cursor.constraint = @ptrCast(@alignCast(wlr_constraint.data));
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
        const group: *KeyboardGroup = @ptrCast(@alignCast(wlr_keyboard.data));

        var buffer: [KeyboardGroup.pressed_count_max]u32 = undefined;
        var keycodes: std.ArrayList(u32) = .initBuffer(&buffer);
        for (group.pressed.keys(), group.pressed.values()) |keycode, press| {
            if (press.consumer == .focus) keycodes.appendAssumeCapacity(keycode);
        }

        seat.wlr_seat.keyboardNotifyEnter(
            wlr_surface,
            keycodes.items,
            &group.state.modifiers,
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

pub fn opUpdate(seat: *Seat, x: i32, y: i32) void {
    const op = &seat.op.?;
    op.x = x;
    op.y = y;
    op.dirty = true;
}

pub fn opEnd(seat: *Seat) void {
    if (seat.op) |op| {
        log.debug("end seat op", .{});
        seat.op = null;
        switch (op.input) {
            .pointer => seat.cursor.opEndPointer(),
        }
    }
}

pub fn attachNewDevice(seat: *Seat, wlr_device: *wlr.InputDevice, virtual: bool) void {
    const device = seat.createDevice(wlr_device, virtual) catch |err| switch (err) {
        error.OutOfMemory => {
            log.err("out of memory", .{});
            return;
        },
    };
    if (device) |d| {
        seat.attachDevice(d);
        seat.updateCapabilities();
    }
}

fn createDevice(seat: *Seat, wlr_device: *wlr.InputDevice, virtual: bool) !?*InputDevice {
    switch (wlr_device.type) {
        .keyboard => {
            const keyboard = try Keyboard.create(seat, wlr_device, virtual);
            return &keyboard.device;
        },
        .pointer, .touch => {
            const device = try util.gpa.create(InputDevice);
            errdefer util.gpa.destroy(device);
            try device.init(seat, wlr_device, virtual);
            return device;
        },
        .tablet => {
            const tablet = try Tablet.create(seat, wlr_device, virtual);
            return &tablet.device;
        },
        .@"switch", .tablet_pad => return null, // unsupported
    }
}

pub fn attachDevice(seat: *Seat, device: *InputDevice) void {
    device.seat = seat;
    switch (device.wlr_device.type) {
        .keyboard => {
            const keyboard: *Keyboard = @fieldParentPtr("device", device);
            keyboard.setGroup();
            if (keyboard.group) |group| {
                seat.wlr_seat.setKeyboard(&group.state);
                if (seat.wlr_seat.keyboard_state.focused_surface) |wlr_surface| {
                    seat.keyboardNotifyEnter(wlr_surface);
                }
            }
        },
        .pointer, .touch, .tablet => {
            seat.cursor.wlr_cursor.attachInputDevice(device.wlr_device);
            seat.cursor.wlr_cursor.mapInputToOutput(device.wlr_device, device.config.map_to_output);
            seat.cursor.wlr_cursor.mapInputToRegion(device.wlr_device, &device.config.map_to_rectangle);
        },
        .@"switch", .tablet_pad => unreachable, // unsupported
    }
}

pub fn detachDevice(seat: *Seat, device: *InputDevice) void {
    seat.cursor.wlr_cursor.detachInputDevice(device.wlr_device);

    if (device.wlr_device.type == .keyboard) {
        const keyboard: *Keyboard = @fieldParentPtr("device", device);
        if (keyboard.group) |group| {
            group.unref();
            keyboard.group = null;
        }
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
            seat.cursor.mode = .drag;
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
