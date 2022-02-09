// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 The River Developers
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

const LockSurface = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const Subsurface = @import("Subsurface.zig");

wlr_lock_surface: *wlr.SessionLockSurfaceV1,
lock: *wlr.SessionLockV1,

output_mode: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleOutputMode),
map: wl.Listener(void) = wl.Listener(void).init(handleMap),
surface_destroy: wl.Listener(void) = wl.Listener(void).init(handleDestroy),
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),
new_subsurface: wl.Listener(*wlr.Subsurface) = wl.Listener(*wlr.Subsurface).init(handleSubsurface),

pub fn create(wlr_lock_surface: *wlr.SessionLockSurfaceV1, lock: *wlr.SessionLockV1) void {
    const lock_surface = util.gpa.create(LockSurface) catch {
        wlr_lock_surface.resource.getClient().postNoMemory();
        return;
    };

    lock_surface.* = .{
        .wlr_lock_surface = wlr_lock_surface,
        .lock = lock,
    };
    wlr_lock_surface.data = @ptrToInt(lock_surface);

    wlr_lock_surface.output.events.mode.add(&lock_surface.output_mode);
    wlr_lock_surface.events.map.add(&lock_surface.map);
    wlr_lock_surface.events.destroy.add(&lock_surface.surface_destroy);
    wlr_lock_surface.surface.events.commit.add(&lock_surface.commit);
    wlr_lock_surface.surface.events.new_subsurface.add(&lock_surface.new_subsurface);

    handleOutputMode(&lock_surface.output_mode, wlr_lock_surface.output);

    Subsurface.handleExisting(wlr_lock_surface.surface, .{ .lock_surface = lock_surface });
}

pub fn destroy(lock_surface: *LockSurface) void {
    lock_surface.output().lock_surface = null;
    if (lock_surface.output().damage) |damage| damage.addWhole();

    {
        var surface_it = lock_surface.lock.surfaces.iterator(.forward);
        const new_focus: Seat.FocusTarget = while (surface_it.next()) |surface| {
            if (surface != lock_surface.wlr_lock_surface)
                break .{ .lock_surface = @intToPtr(*LockSurface, surface.data) };
        } else .none;

        var seat_it = server.input_manager.seats.first;
        while (seat_it) |node| : (seat_it = node.next) {
            const seat = &node.data;
            if (seat.focused == .lock_surface and seat.focused.lock_surface == lock_surface) {
                seat.setFocusRaw(new_focus);
            }
            seat.cursor.updateState();
        }
    }

    lock_surface.output_mode.link.remove();
    lock_surface.map.link.remove();
    lock_surface.surface_destroy.link.remove();
    lock_surface.commit.link.remove();
    lock_surface.new_subsurface.link.remove();

    Subsurface.destroySubsurfaces(lock_surface.wlr_lock_surface.surface);

    util.gpa.destroy(lock_surface);
}

pub fn output(lock_surface: *LockSurface) *Output {
    return @intToPtr(*Output, lock_surface.wlr_lock_surface.output.data);
}

fn handleOutputMode(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const lock_surface = @fieldParentPtr(LockSurface, "output_mode", listener);

    const res = lock_surface.output().getEffectiveResolution();
    _ = lock_surface.wlr_lock_surface.configure(res.width, res.height);
}

fn handleMap(listener: *wl.Listener(void)) void {
    const lock_surface = @fieldParentPtr(LockSurface, "map", listener);

    {
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) {
            const seat = &node.data;
            if (seat.focused != .lock_surface) {
                seat.setFocusRaw(.{ .lock_surface = lock_surface });
            }
        }
    }

    lock_surface.output().lock_surface = lock_surface;
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const lock_surface = @fieldParentPtr(LockSurface, "surface_destroy", listener);

    lock_surface.destroy();
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const lock_surface = @fieldParentPtr(LockSurface, "commit", listener);

    lock_surface.output().damage.?.addWhole();
}

fn handleSubsurface(listener: *wl.Listener(*wlr.Subsurface), subsurface: *wlr.Subsurface) void {
    const lock_surface = @fieldParentPtr(LockSurface, "new_subsurface", listener);
    Subsurface.create(subsurface, .{ .lock_surface = lock_surface });
}
