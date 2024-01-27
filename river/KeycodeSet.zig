// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2022 - 2024 The River Developers
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

const Self = @This();

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.keyboard);

const wlr = @import("wlroots");

const EatReason = enum {
    /// Not eaten
    none,
    mapping,
    im_grab,
};

items: [32]u32 = undefined,
reason: [32]EatReason = undefined,
len: usize = 0,

pub fn add(self: *Self, new: u32, reason: EatReason) EatReason {
    for (self.items[0..self.len]) |item| assert(new != item);

    comptime assert(@typeInfo(std.meta.fieldInfo(Self, .items).type).Array.len ==
        @typeInfo(std.meta.fieldInfo(wlr.Keyboard, .keycodes).type).Array.len);

    if (self.len == self.items.len) {
        log.err("KeycodeSet limit reached, code {d} omitted", .{new});
        // We can't eat the release, don't eat the press
        return .none;
    }

    self.items[self.len] = new;
    self.reason[self.len] = reason;
    self.len += 1;

    return reason;
}

pub fn remove(self: *Self, old: u32) EatReason {
    for (self.items[0..self.len], self.reason[0..self.len], 0..) |item, reason, idx| {
        if (old == item) {
            self.len -= 1;
            if (self.len > 0) {
                self.items[idx] = self.items[self.len];
                self.reason[idx] = self.reason[self.len];
            }

            return reason;
        }
    }

    return .none;
}

/// Removes other's contents from self (if present), regardless of reason
pub fn subtract(self: *Self, other: Self) void {
    for (other.items[0..other.len]) |item| _ = self.remove(item);
}
