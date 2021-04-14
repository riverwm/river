// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020-2021 The River Developers
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
const OutputOption = @import("OutputOption.zig");

const log = std.log.scoped(.river_options);

pub const Value = union(enum) {
    int: i32,
    uint: u32,
    fixed: wl.Fixed,
    string: ?[*:0]const u8,

    pub fn dupe(value: Value) !Value {
        return switch (value) {
            .string => |v| Value{ .string = if (v) |s| try util.gpa.dupeZ(u8, mem.span(s)) else null },
            else => value,
        };
    }

    pub fn deinit(value: *Value) void {
        if (value.* == .string) if (value.string) |s| util.gpa.free(mem.span(s));
    }
};

options_manager: *OptionsManager,
link: wl.list.Link = undefined,

key: [:0]const u8,
value: Value,

output_options: wl.list.Head(OutputOption, "link") = undefined,

event: struct {
    /// Emitted whenever the value of the option changes.
    update: wl.Signal(*Value),
} = undefined,

handles: wl.list.Head(river.OptionHandleV2, null) = undefined,

/// Allocate a new option, duping the provided key and value
pub fn create(options_manager: *OptionsManager, key: [*:0]const u8, value: Value) !void {
    const self = try util.gpa.create(Self);
    errdefer util.gpa.destroy(self);

    var owned_value = try value.dupe();
    errdefer owned_value.deinit();

    self.* = .{
        .options_manager = options_manager,
        .key = try util.gpa.dupeZ(u8, mem.span(key)),
        .value = owned_value,
    };
    errdefer util.gpa.free(self.key);

    self.output_options.init();
    errdefer {
        var it = self.output_options.safeIterator(.forward);
        while (it.next()) |output_option| output_option.destroy();
    }
    var it = options_manager.server.root.all_outputs.first;
    while (it) |node| : (it = node.next) try OutputOption.create(self, node.data);

    self.event.update.init();
    self.handles.init();

    options_manager.options.append(self);
}

pub fn destroy(self: *Self) void {
    {
        var it = self.handles.safeIterator(.forward);
        while (it.next()) |handle| handle.destroy();
    }
    {
        var it = self.output_options.safeIterator(.forward);
        while (it.next()) |output_option| output_option.destroy();
    }
    self.value.deinit();
    self.link.remove();
    util.gpa.destroy(self);
}

pub fn getOutputOption(self: *Self, output: *Output) ?*OutputOption {
    var it = self.output_options.iterator(.forward);
    while (it.next()) |output_option| {
        if (output_option.output == output) return output_option;
    } else return null;
}

/// If the value is a string, the string is cloned.
/// If the value is changed, send the proper event to all clients
pub fn set(self: *Self, value: Value) !void {
    if (meta.activeTag(value) != meta.activeTag(self.value)) return error.TypeMismatch;

    self.value.deinit();
    self.value = try value.dupe();

    {
        var it = self.handles.iterator(.forward);
        while (it.next()) |handle| self.sendValue(handle);
    }
    {
        var it = self.output_options.iterator(.forward);
        while (it.next()) |output_option| {
            if (output_option.value == null) output_option.notifyChanged();
        }
    }

    self.event.update.emit(&self.value);
}

pub fn sendValue(self: Self, handle: *river.OptionHandleV2) void {
    switch (self.value) {
        .int => |v| handle.sendIntValue(v),
        .uint => |v| handle.sendUintValue(v),
        .fixed => |v| handle.sendFixedValue(v),
        .string => |v| handle.sendStringValue(v),
    }
}

pub fn addHandle(self: *Self, output: ?*Output, handle: *river.OptionHandleV2) void {
    if (output) |o| {
        self.getOutputOption(o).?.addHandle(handle);
    } else {
        self.handles.append(handle);
        self.sendValue(handle);
        handle.setHandler(*Self, handleRequest, handleDestroy, self);
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
