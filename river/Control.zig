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

const std = @import("std");
const mem = std.mem;

const wayland = @import("wayland");
const wl = wayland.server.wl;
const zriver = wayland.server.zriver;

const wlr = @import("wlroots");

const c = @import("c.zig");
const command = @import("command.zig");
const util = @import("util.zig");

const Seat = @import("Seat.zig");
const Server = @import("Server.zig");

global: *wl.Global,

args_map: std.AutoHashMap(u32, std.ArrayList([]const u8)),

server_destroy: wl.Listener(*wl.Server) = wl.Listener(*wl.Server).init(handleServerDestroy),

pub fn init(self: *Self, server: *Server) !void {
    self.* = .{
        .global = try wl.Global.create(server.wl_server, zriver.ControlV1, 1, *Self, self, bind),
        .args_map = std.AutoHashMap(u32, std.ArrayList([]const u8)).init(util.gpa),
    };

    server.wl_server.addDestroyListener(&self.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), wl_server: *wl.Server) void {
    const self = @fieldParentPtr(Self, "server_destroy", listener);
    self.global.destroy();
    self.args_map.deinit();
}

/// Called when a client binds our global
fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) callconv(.C) void {
    const control = zriver.ControlV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    self.args_map.putNoClobber(id, std.ArrayList([]const u8).init(util.gpa)) catch {
        control.destroy();
        client.postNoMemory();
        return;
    };
    control.setHandler(*Self, handleRequest, handleDestroy, self);
}

fn handleRequest(control: *zriver.ControlV1, request: zriver.ControlV1.Request, self: *Self) void {
    switch (request) {
        .destroy => control.destroy(),
        .add_argument => |add_argument| {
            const owned_slice = mem.dupe(util.gpa, u8, mem.span(add_argument.argument)) catch {
                control.getClient().postNoMemory();
                return;
            };

            self.args_map.getEntry(control.getId()).?.value.append(owned_slice) catch {
                control.getClient().postNoMemory();
                util.gpa.free(owned_slice);
                return;
            };
        },
        .run_command => |run_command| {
            const seat = @intToPtr(*Seat, wlr.Seat.Client.fromWlSeat(run_command.seat).?.seat.data);

            const callback = zriver.CommandCallbackV1.create(
                control.getClient(),
                control.getVersion(),
                run_command.callback,
            ) catch {
                control.getClient().postNoMemory();
                return;
            };

            const args = self.args_map.get(control.getId()).?.items;

            var out: ?[]const u8 = null;
            defer if (out) |s| util.gpa.free(s);
            command.run(util.gpa, seat, args, &out) catch |err| {
                const failure_message = switch (err) {
                    command.Error.OutOfMemory => {
                        callback.getClient().postNoMemory();
                        return;
                    },
                    command.Error.Other => std.cstr.addNullByte(util.gpa, out.?) catch {
                        callback.getClient().postNoMemory();
                        return;
                    },
                    else => command.errToMsg(err),
                };
                defer if (err == command.Error.Other) util.gpa.free(failure_message);
                callback.sendFailure(failure_message);
                return;
            };

            const success_message = if (out) |s|
                std.cstr.addNullByte(util.gpa, s) catch {
                    callback.getClient().postNoMemory();
                    return;
                }
            else
                "";
            defer if (out != null) util.gpa.free(success_message);
            callback.sendSuccess(success_message);
        },
    }
}

/// Remove the resource from the hash map and free all stored args
fn handleDestroy(control: *zriver.ControlV1, self: *Self) void {
    const list = self.args_map.remove(control.getId()).?.value;
    for (list.items) |arg| list.allocator.free(arg);
    list.deinit();
}
