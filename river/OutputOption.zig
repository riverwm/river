// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 The River Developers
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
const meta = std.meta;

const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const util = @import("util.zig");

const Output = @import("Output.zig");
const OptionsManager = @import("OptionsManager.zig");
const Option = @import("Option.zig");

const Value = Option.Value;

option: *Option,

link: wl.list.Link = undefined,

output: *Output,
value: ?Value = null,

event: struct {
    /// Emitted whenever the value of the option changes.
    update: wl.Signal(*Value),
} = undefined,

handles: wl.list.Head(river.OptionHandleV2, null) = undefined,

pub fn create(option: *Option, output: *Output) !void {
    const self = try util.gpa.create(Self);
    errdefer util.gpa.destroy(self);

    self.* = .{ .option = option, .output = output };
    self.event.update.init();
    self.handles.init();

    option.output_options.append(self);
}

pub fn destroy(self: *Self) void {
    if (self.value) |*value| value.deinit();
    self.link.remove();
    util.gpa.destroy(self);
}

pub fn addHandle(self: *Self, handle: *river.OptionHandleV2) void {
    self.handles.append(handle);
    self.sendValue(handle);
    handle.setHandler(*Self, handleRequest, handleDestroy, self);
}

pub fn unset(self: *Self) void {
    if (self.value) |*value| value.deinit();
    self.value = null;

    // Unsetting the output-specific value causes us to fall back to the
    // global value. Send this new value to all clients.
    var it = self.handles.iterator(.forward);
    while (it.next()) |handle| {
        self.option.sendValue(handle);
    }

    self.event.update.emit(&self.option.value);
}

/// If the value is a string, the string is cloned.
/// If the value is changed, send the proper event to all clients
pub fn set(self: *Self, value: Value) !void {
    if (meta.activeTag(value) != meta.activeTag(self.option.value)) return error.TypeMismatch;

    if (self.value) |*v| v.deinit();
    self.value = try value.dupe();

    self.notifyChanged();
}

pub fn notifyChanged(self: *Self) void {
    var it = self.handles.iterator(.forward);
    while (it.next()) |handle| self.sendValue(handle);
    self.event.update.emit(self.get());
}

pub fn get(self: *Self) *Value {
    return if (self.value) |*value| value else &self.option.value;
}

fn sendValue(self: Self, handle: *river.OptionHandleV2) void {
    if (self.value) |value| {
        switch (value) {
            .int => |v| handle.sendIntValue(v),
            .uint => |v| handle.sendUintValue(v),
            .fixed => |v| handle.sendFixedValue(v),
            .string => |v| handle.sendStringValue(v),
        }
    } else {
        self.option.sendValue(handle);
    }
}

fn handleRequest(handle: *river.OptionHandleV2, request: river.OptionHandleV2.Request, self: *Self) void {
    switch (request) {
        .destroy => handle.destroy(),
        .set_int_value => |req| self.set(.{ .int = req.value }) catch |err| switch (err) {
            error.TypeMismatch => handle.postError(.type_mismatch, "option is not of type int"),
            error.OutOfMemory => unreachable,
        },
        .set_uint_value => |req| self.set(.{ .uint = req.value }) catch |err| switch (err) {
            error.TypeMismatch => handle.postError(.type_mismatch, "option is not of type uint"),
            error.OutOfMemory => unreachable,
        },
        .set_fixed_value => |req| self.set(.{ .fixed = req.value }) catch |err| switch (err) {
            error.TypeMismatch => handle.postError(.type_mismatch, "option is not of type fixed"),
            error.OutOfMemory => unreachable,
        },
        .set_string_value => |req| self.set(.{ .string = req.value }) catch |err| switch (err) {
            error.TypeMismatch => handle.postError(.type_mismatch, "option is not of type string"),
            error.OutOfMemory => handle.getClient().postNoMemory(),
        },
    }
}

fn handleDestroy(handle: *river.OptionHandleV2, self: *Self) void {
    handle.getLink().remove();
}
