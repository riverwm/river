// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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

const Control = @This();

const std = @import("std");
const mem = std.mem;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zriver = wayland.server.zriver;

const command = @import("command.zig");
const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");
const Server = @import("Server.zig");

const ArgMap = std.AutoHashMap(struct { client: *wl.Client, id: u32 }, std.ArrayListUnmanaged([:0]const u8));

global: *wl.Global,

args_map: ArgMap,

server_destroy: wl.Listener(*wl.Server) = wl.Listener(*wl.Server).init(handleServerDestroy),

pub fn init(control: *Control) !void {
    control.* = .{
        .global = try wl.Global.create(server.wl_server, zriver.ControlV1, 1, *Control, control, bind),
        .args_map = ArgMap.init(util.gpa),
    };

    server.wl_server.addDestroyListener(&control.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const control = @fieldParentPtr(Control, "server_destroy", listener);
    control.global.destroy();
    control.args_map.deinit();
}

/// Called when a client binds our global
fn bind(client: *wl.Client, control: *Control, version: u32, id: u32) void {
    const control_v1 = zriver.ControlV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    control.args_map.putNoClobber(.{ .client = client, .id = id }, .{}) catch {
        control_v1.destroy();
        client.postNoMemory();
        return;
    };
    control_v1.setHandler(*Control, handleRequest, handleDestroy, control);
}

fn handleRequest(control_v1: *zriver.ControlV1, request: zriver.ControlV1.Request, control: *Control) void {
    switch (request) {
        .destroy => control_v1.destroy(),
        .add_argument => |add_argument| {
            const owned_slice = util.gpa.dupeZ(u8, mem.sliceTo(add_argument.argument, 0)) catch {
                control_v1.getClient().postNoMemory();
                return;
            };

            const args = control.args_map.getPtr(.{ .client = control_v1.getClient(), .id = control_v1.getId() }).?;
            args.append(util.gpa, owned_slice) catch {
                control_v1.getClient().postNoMemory();
                util.gpa.free(owned_slice);
                return;
            };
        },
        .run_command => |run_command| {
            const seat: *Seat = @ptrFromInt(wlr.Seat.Client.fromWlSeat(run_command.seat).?.seat.data);

            const callback = zriver.CommandCallbackV1.create(
                control_v1.getClient(),
                control_v1.getVersion(),
                run_command.callback,
            ) catch {
                control_v1.getClient().postNoMemory();
                return;
            };

            const args = control.args_map.getPtr(.{ .client = control_v1.getClient(), .id = control_v1.getId() }).?;
            defer {
                for (args.items) |arg| util.gpa.free(arg);
                args.items.len = 0;
            }

            var out: ?[]const u8 = null;
            defer if (out) |s| util.gpa.free(s);
            command.run(seat, args.items, &out) catch |err| {
                const failure_message = switch (err) {
                    command.Error.OutOfMemory => {
                        callback.getClient().postNoMemory();
                        return;
                    },
                    command.Error.Other => util.gpa.dupeZ(u8, out.?) catch {
                        callback.getClient().postNoMemory();
                        return;
                    },
                    else => command.errToMsg(err),
                };
                defer if (err == command.Error.Other) util.gpa.free(failure_message);
                callback.destroySendFailure(failure_message);
                return;
            };

            const success_message = if (out) |s|
                util.gpa.dupeZ(u8, s) catch {
                    callback.getClient().postNoMemory();
                    return;
                }
            else
                "";
            defer if (out != null) util.gpa.free(success_message);
            callback.destroySendSuccess(success_message);
        },
    }
}

/// Remove the resource from the hash map and free all stored args
fn handleDestroy(control_v1: *zriver.ControlV1, control: *Control) void {
    var args = control.args_map.fetchRemove(
        .{ .client = control_v1.getClient(), .id = control_v1.getId() },
    ).?.value;
    for (args.items) |arg| util.gpa.free(arg);
    args.deinit(util.gpa);
}
