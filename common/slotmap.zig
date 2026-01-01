// SPDX-FileCopyrightText: © 2025 Isaac Freund
// SPDX-License-Identifier: 0BSD

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

pub fn SlotMap(comptime T: type) type {
    return struct {
        const Map = @This();

        /// This is packed just to make == work.
        pub const Key = packed struct {
            generation: u32,
            index: u32,
        };

        const Slot = struct {
            generation: u32,
            data: union(enum) {
                value: T,
                // Index of the next free slot or slots.items.len + 1 if
                // this is the last free slot.
                next_free: u32,
            },
        };

        slots: std.ArrayListUnmanaged(Slot),
        /// Number of values stored in the map.
        count: u32,
        /// Index of the first free slot or slots.items.len + 1 if there
        /// is no free slot.
        first_free: u32,

        pub const empty: Map = .{
            .slots = .empty,
            .count = 0,
            .first_free = 1,
        };

        pub fn deinit(map: *Map, gpa: mem.Allocator) void {
            map.slots.deinit(gpa);
        }

        pub fn put(map: *Map, gpa: mem.Allocator, value: T) error{OutOfMemory}!Key {
            if (map.first_free < map.slots.items.len) {
                const index = map.first_free;
                const slot = &map.slots.items[index];
                map.first_free = slot.data.next_free;
                slot.data = .{ .value = value };
                map.count += 1;
                return .{
                    .generation = slot.generation,
                    .index = index,
                };
            }
            try map.slots.append(gpa, .{
                .generation = 0,
                .data = .{ .value = value },
            });
            map.count += 1;
            map.first_free += 1;
            return .{
                .generation = 0,
                .index = @intCast(map.slots.items.len - 1),
            };
        }

        pub fn get(map: *Map, key: Key) ?T {
            if (map.getSlot(key)) |slot| {
                return slot.data.value;
            }
            return null;
        }

        pub fn remove(map: *Map, key: Key) void {
            if (map.getSlot(key)) |slot| {
                assert(slot.data == .value);
                slot.* = .{
                    .generation = slot.generation +% 1,
                    .data = .{ .next_free = map.first_free },
                };
                map.count -= 1;
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

        pub const Iterator = struct {
            map: *Map,
            index: u32,

            pub fn next(it: *Iterator) ?T {
                while (it.index < it.map.slots.items.len) {
                    defer it.index += 1;
                    switch (it.map.slots.items[it.index].data) {
                        .value => |value| return value,
                        .next_free => {},
                    }
                }
                return null;
            }
        };

        /// Removing values from the map during iteration is safe.
        /// Adding values to the map during iteration is safe but there is
        /// no guarantee whether or not values added during iteration will
        /// be seen by the iterator.
        pub fn iterator(map: *Map) Iterator {
            return .{ .map = map, .index = 0 };
        }
    };
}

// TODO fuzz test?
test "basic" {
    const testing = std.testing;

    var map: SlotMap(u32) = .empty;
    defer map.deinit(testing.allocator);

    const five = try map.put(testing.allocator, 5);
    try testing.expectEqual(5, map.get(five));
    try testing.expectEqual(5, map.get(five));

    map.remove(five);
    try testing.expectEqual(null, map.get(five));

    map.remove(five);
    try testing.expectEqual(null, map.get(five));

    const six = try map.put(testing.allocator, 6);
    try testing.expectEqual(6, map.get(six));
    try testing.expectEqual(null, map.get(five));
    try testing.expectEqual(6, map.get(six));

    map.remove(five);
    try testing.expectEqual(null, map.get(five));
    try testing.expectEqual(6, map.get(six));

    const seven = try map.put(testing.allocator, 7);
    const eight = try map.put(testing.allocator, 8);
    const nine = try map.put(testing.allocator, 9);
    try testing.expectEqual(null, map.get(five));
    try testing.expectEqual(6, map.get(six));
    try testing.expectEqual(7, map.get(seven));
    try testing.expectEqual(8, map.get(eight));
    try testing.expectEqual(9, map.get(nine));

    map.remove(five);
    map.remove(eight);
    try testing.expectEqual(null, map.get(five));
    try testing.expectEqual(6, map.get(six));
    try testing.expectEqual(7, map.get(seven));
    try testing.expectEqual(null, map.get(eight));
    try testing.expectEqual(9, map.get(nine));

    try testing.expectEqual(null, map.get(five));
    try testing.expectEqual(6, map.get(six));
    try testing.expectEqual(7, map.get(seven));
    try testing.expectEqual(null, map.get(eight));
    try testing.expectEqual(9, map.get(nine));
}

test "iteration" {
    const testing = std.testing;

    var map: SlotMap(u64) = .empty;
    defer map.deinit(testing.allocator);

    {
        var it = map.iterator();
        try testing.expectEqual(null, it.next());
    }

    const five = try map.put(testing.allocator, 5);
    const six = try map.put(testing.allocator, 6);
    const seven = try map.put(testing.allocator, 7);
    const eight = try map.put(testing.allocator, 8);
    const nine = try map.put(testing.allocator, 9);

    try testing.expectEqual(5, map.get(five));
    try testing.expectEqual(6, map.get(six));
    try testing.expectEqual(7, map.get(seven));
    try testing.expectEqual(8, map.get(eight));
    try testing.expectEqual(9, map.get(nine));
    try expectIterate(&.{ 5, 6, 7, 8, 9 }, &map);

    map.remove(seven);
    try testing.expectEqual(5, map.get(five));
    try testing.expectEqual(6, map.get(six));
    try testing.expectEqual(null, map.get(seven));
    try testing.expectEqual(8, map.get(eight));
    try testing.expectEqual(9, map.get(nine));
    try expectIterate(&.{ 5, 6, 8, 9 }, &map);

    const ten = try map.put(testing.allocator, 10);
    try testing.expectEqual(5, map.get(five));
    try testing.expectEqual(6, map.get(six));
    try testing.expectEqual(null, map.get(seven));
    try testing.expectEqual(8, map.get(eight));
    try testing.expectEqual(9, map.get(nine));
    try testing.expectEqual(10, map.get(ten));
    try expectIterate(&.{ 5, 6, 10, 8, 9 }, &map);

    map.remove(five);
    map.remove(nine);
    map.remove(six);
    try testing.expectEqual(null, map.get(five));
    try testing.expectEqual(null, map.get(six));
    try testing.expectEqual(null, map.get(seven));
    try testing.expectEqual(8, map.get(eight));
    try testing.expectEqual(null, map.get(nine));
    try testing.expectEqual(10, map.get(ten));
    try expectIterate(&.{ 10, 8 }, &map);
}

fn expectIterate(expected: []const u64, map: *SlotMap(u64)) !void {
    var it = map.iterator();
    var i: u32 = 0;
    while (it.next()) |value| : (i += 1) {
        try std.testing.expect(i < expected.len);
        try std.testing.expectEqual(expected[i], value);
    }
    try std.testing.expectEqual(i, map.count);
    try std.testing.expectEqual(i, expected.len);
}

test "remove during iteration" {
    const testing = std.testing;

    var map: SlotMap(u64) = .empty;
    defer map.deinit(testing.allocator);

    const five = try map.put(testing.allocator, 5);
    const six = try map.put(testing.allocator, 6);
    const seven = try map.put(testing.allocator, 7);
    const eight = try map.put(testing.allocator, 8);
    const nine = try map.put(testing.allocator, 9);

    try testing.expectEqual(5, map.get(five));
    try testing.expectEqual(6, map.get(six));
    try testing.expectEqual(7, map.get(seven));
    try testing.expectEqual(8, map.get(eight));
    try testing.expectEqual(9, map.get(nine));
    try expectIterate(&.{ 5, 6, 7, 8, 9 }, &map);

    var it = map.iterator();
    map.remove(five);

    try testing.expectEqual(6, it.next());
    try testing.expectEqual(null, map.get(five));
    try testing.expectEqual(6, map.get(six));
    try testing.expectEqual(7, map.get(seven));
    try testing.expectEqual(8, map.get(eight));
    try testing.expectEqual(9, map.get(nine));

    try testing.expectEqual(7, it.next());
    map.remove(seven);
    map.remove(nine);
    map.remove(eight);
    try testing.expectEqual(null, it.next());
}
