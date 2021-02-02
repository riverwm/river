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
const meta = std.meta;

const wayland = @import("wayland");
const wl = wayland.server.wl;
const zriver = wayland.server.zriver;

const util = @import("util.zig");

const Output = @import("Output.zig");
const OptionsManager = @import("OptionsManager.zig");

pub const Value = union(enum) {
    unset: void,
    int: i32,
    uint: u32,
    fixed: wl.Fixed,
    string: ?[*:0]const u8,
};

options_manager: *OptionsManager,
link: wl.list.Link = undefined,

output: ?*Output,
key: [*:0]const u8,
value: Value = .unset,

/// Emitted whenever the value of the option changes.
update: wl.Signal(*Self) = undefined,

handles: wl.list.Head(zriver.OptionHandleV1, null) = undefined,

pub fn create(options_manager: *OptionsManager, output: ?*Output, key: [*:0]const u8) !*Self {
    const self = try util.gpa.create(Self);
    errdefer util.gpa.destroy(self);

    self.* = .{
        .options_manager = options_manager,
        .output = output,
        .key = try util.gpa.dupeZ(u8, mem.span(key)),
    };
    self.handles.init();
    self.update.init();

    options_manager.options.append(self);

    return self;
}

pub fn destroy(self: *Self) void {
    var it = self.handles.safeIterator(.forward);
    while (it.next()) |handle| handle.destroy();
    if (self.value == .string) if (self.value.string) |s| util.gpa.free(mem.span(s));
    self.link.remove();
    util.gpa.destroy(self);
}

/// Asserts that the new value is not .unset.
/// Ignores the new value if the value is currently set and the type does not match.
/// If the value is a string, the string is cloned.
/// If the value is changed, send the proper event to all clients
pub fn set(self: *Self, value: Value) !void {
    std.debug.assert(value != .unset);
    if (self.value != .unset and meta.activeTag(value) != meta.activeTag(self.value)) return;

    if (self.value == .unset and value == .string) {
        self.value = .{
            .string = if (value.string) |s| (try util.gpa.dupeZ(u8, mem.span(s))).ptr else null,
        };
    } else if (self.value == .string and
        // TODO: std.mem needs a good way to compare optional sentinel pointers
        (((self.value.string == null) != (value.string == null)) or
        (self.value.string != null and value.string != null and
        std.cstr.cmp(self.value.string.?, value.string.?) != 0)))
    {
        const owned_string = if (value.string) |s| (try util.gpa.dupeZ(u8, mem.span(s))).ptr else null;
        if (self.value.string) |s| util.gpa.free(mem.span(s));
        self.value.string = owned_string;
    } else if (self.value == .unset or (self.value != .string and !std.meta.eql(self.value, value))) {
        self.value = value;
    } else {
        // The value was not changed
        return;
    }

    var it = self.handles.iterator(.forward);
    while (it.next()) |handle| self.sendValue(handle);

    // Call listeners, if any.
    self.update.emit(self);
}

fn sendValue(self: Self, handle: *zriver.OptionHandleV1) void {
    switch (self.value) {
        .unset => handle.sendUnset(),
        .int => |v| handle.sendIntValue(v),
        .uint => |v| handle.sendUintValue(v),
        .fixed => |v| handle.sendFixedValue(v),
        .string => |v| handle.sendStringValue(v),
    }
}

pub fn addHandle(self: *Self, handle: *zriver.OptionHandleV1) void {
    self.handles.append(handle);
    self.sendValue(handle);
    handle.setHandler(*Self, handleRequest, handleDestroy, self);
}

fn handleRequest(handle: *zriver.OptionHandleV1, request: zriver.OptionHandleV1.Request, self: *Self) void {
    switch (request) {
        .destroy => handle.destroy(),
        .set_int_value => |req| self.set(.{ .int = req.value }) catch unreachable,
        .set_uint_value => |req| self.set(.{ .uint = req.value }) catch unreachable,
        .set_fixed_value => |req| self.set(.{ .fixed = req.value }) catch unreachable,
        .set_string_value => |req| self.set(.{ .string = req.value }) catch {
            handle.getClient().postNoMemory();
        },
    }
}

fn handleDestroy(handle: *zriver.OptionHandleV1, self: *Self) void {
    handle.getLink().remove();
}
