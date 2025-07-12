// Released under the Zero Clause BSD (0BSD) license:
//
// Copyright 2025 Isaac Freund
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

pub fn SlotMap(comptime T: type) type {
    return struct {
        const Map = @This();

        pub const Key = struct {
            generation: u32,
            index: u32,
        };

        const Slot = struct {
            generation: u32,
            data: union {
                // Valid if generation is even.
                value: T,
                // Index of the next free slot or slots.items.len + 1 if
                // this is the last free slot. Valid if generation is odd.
                next_free: u32,
            },

            fn hasValue(slot: *const Slot) bool {
                return slot.generation % 2 == 0;
            }
        };

        slots: std.ArrayListUnmanaged(Slot),
        /// Index of the first free slot or slots.items.len + 1 if there
        /// is no free slot.
        first_free: u32,

        pub const empty: Map = .{
            .slots = .empty,
            .first_free = 1,
        };

        pub fn deinit(map: *Map, gpa: mem.Allocator) void {
            map.slots.deinit(gpa);
        }

        pub fn put(map: *Map, gpa: mem.Allocator, value: T) error{OutOfMemory}!Key {
            if (map.first_free < map.slots.items.len) {
                const index = map.first_free;
                const slot = &map.slots.items[index];
                assert(!slot.hasValue());
                map.first_free = slot.data.next_free;
                slot.* = .{
                    .generation = slot.generation + 1,
                    .data = .{ .value = value },
                };
                return .{
                    .index = index,
                    .generation = slot.generation,
                };
            }
            try map.slots.append(gpa, .{
                .generation = 0,
                .data = .{ .value = value },
            });
            map.first_free += 1;
            return .{
                .index = @intCast(map.slots.items.len - 1),
                .generation = 0,
            };
        }

        pub fn get(map: *Map, key: Key) ?T {
            if (map.getSlot(key)) |slot| {
                assert(slot.hasValue());
                return slot.data.value;
            }
            return null;
        }

        pub fn remove(map: *Map, key: Key) void {
            if (map.getSlot(key)) |slot| {
                assert(slot.hasValue());
                slot.* = .{
                    .generation = slot.generation +% 1,
                    .data = .{ .next_free = map.first_free },
                };
                map.first_free = key.index;
            }
        }

        fn getSlot(map: *Map, key: Key) ?*Slot {
            if (key.index < map.slots.items.len) {
                if (key.generation == map.slots.items[key.index].generation) {
                    return &map.slots.items[key.index];
                }
            }
            return null;
        }
    };
}

// TODO fuzz test?
test "basic" {
    const testing = std.testing;

    var map: SlotMap(u32) = .empty;
    defer map.deinit(testing.allocator);

    const five = try map.put(testing.allocator, 5);
    try testing.expectEqual(@as(?u32, 5), map.get(five));
    try testing.expectEqual(@as(?u32, 5), map.get(five));

    map.remove(five);
    try testing.expectEqual(@as(?u32, null), map.get(five));

    map.remove(five);
    try testing.expectEqual(@as(?u32, null), map.get(five));

    const six = try map.put(testing.allocator, 6);
    try testing.expectEqual(@as(?u32, 6), map.get(six));
    try testing.expectEqual(@as(?u32, null), map.get(five));
    try testing.expectEqual(@as(?u32, 6), map.get(six));

    map.remove(five);
    try testing.expectEqual(@as(?u32, null), map.get(five));
    try testing.expectEqual(@as(?u32, 6), map.get(six));

    const seven = try map.put(testing.allocator, 7);
    const eight = try map.put(testing.allocator, 8);
    const nine = try map.put(testing.allocator, 9);
    try testing.expectEqual(@as(?u32, null), map.get(five));
    try testing.expectEqual(@as(?u32, 6), map.get(six));
    try testing.expectEqual(@as(?u32, 7), map.get(seven));
    try testing.expectEqual(@as(?u32, 8), map.get(eight));
    try testing.expectEqual(@as(?u32, 9), map.get(nine));

    map.remove(five);
    map.remove(eight);
    try testing.expectEqual(@as(?u32, null), map.get(five));
    try testing.expectEqual(@as(?u32, 6), map.get(six));
    try testing.expectEqual(@as(?u32, 7), map.get(seven));
    try testing.expectEqual(@as(?u32, null), map.get(eight));
    try testing.expectEqual(@as(?u32, 9), map.get(nine));

    try testing.expectEqual(@as(?u32, null), map.get(five));
    try testing.expectEqual(@as(?u32, 6), map.get(six));
    try testing.expectEqual(@as(?u32, 7), map.get(seven));
    try testing.expectEqual(@as(?u32, null), map.get(eight));
    try testing.expectEqual(@as(?u32, 9), map.get(nine));
}
