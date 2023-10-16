// Basic prefix, suffix, and substring glob matching.
//
// Released under the Zero Clause BSD (0BSD) license:
//
// Copyright 2023 Isaac Freund
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
const mem = std.mem;

/// Validate a glob, returning error.InvalidGlob if it is empty, "**" or has a
/// '*' at any position other than the first and/or last byte.
pub fn validate(glob: []const u8) error{InvalidGlob}!void {
    switch (glob.len) {
        0 => return error.InvalidGlob,
        1 => {},
        2 => if (glob[0] == '*' and glob[1] == '*') return error.InvalidGlob,
        else => if (mem.indexOfScalar(u8, glob[1 .. glob.len - 1], '*') != null) {
            return error.InvalidGlob;
        },
    }
}

test validate {
    const testing = std.testing;

    try validate("*");
    try validate("a");
    try validate("*a");
    try validate("a*");
    try validate("*a*");
    try validate("ab");
    try validate("*ab");
    try validate("ab*");
    try validate("*ab*");
    try validate("abc");
    try validate("*abc");
    try validate("abc*");
    try validate("*abc*");

    try testing.expectError(error.InvalidGlob, validate(""));
    try testing.expectError(error.InvalidGlob, validate("**"));
    try testing.expectError(error.InvalidGlob, validate("***"));
    try testing.expectError(error.InvalidGlob, validate("a*c"));
    try testing.expectError(error.InvalidGlob, validate("ab*c*"));
    try testing.expectError(error.InvalidGlob, validate("*ab*c"));
    try testing.expectError(error.InvalidGlob, validate("ab*c"));
    try testing.expectError(error.InvalidGlob, validate("a*bc*"));
    try testing.expectError(error.InvalidGlob, validate("**a"));
    try testing.expectError(error.InvalidGlob, validate("abc**"));
}

/// Return true if s is matched by glob.
/// Asserts that the glob is valid, see `validate()`.
pub fn match(s: []const u8, glob: []const u8) bool {
    if (std.debug.runtime_safety) {
        validate(glob) catch unreachable;
    }

    if (glob.len == 1) {
        return glob[0] == '*' or mem.eql(u8, s, glob);
    }

    const suffix_match = glob[0] == '*';
    const prefix_match = glob[glob.len - 1] == '*';

    if (suffix_match and prefix_match) {
        return mem.indexOf(u8, s, glob[1 .. glob.len - 1]) != null;
    } else if (suffix_match) {
        return mem.endsWith(u8, s, glob[1..]);
    } else if (prefix_match) {
        return mem.startsWith(u8, s, glob[0 .. glob.len - 1]);
    } else {
        return mem.eql(u8, s, glob);
    }
}

test match {
    const testing = std.testing;

    try testing.expect(match("", "*"));

    try testing.expect(match("a", "*"));
    try testing.expect(match("a", "*a*"));
    try testing.expect(match("a", "a*"));
    try testing.expect(match("a", "*a"));
    try testing.expect(match("a", "a"));

    try testing.expect(!match("a", "b"));
    try testing.expect(!match("a", "*b*"));
    try testing.expect(!match("a", "b*"));
    try testing.expect(!match("a", "*b"));

    try testing.expect(match("ab", "*"));
    try testing.expect(match("ab", "*a*"));
    try testing.expect(match("ab", "*b*"));
    try testing.expect(match("ab", "a*"));
    try testing.expect(match("ab", "*b"));
    try testing.expect(match("ab", "*ab*"));
    try testing.expect(match("ab", "ab*"));
    try testing.expect(match("ab", "*ab"));
    try testing.expect(match("ab", "ab"));

    try testing.expect(!match("ab", "b*"));
    try testing.expect(!match("ab", "*a"));
    try testing.expect(!match("ab", "*c*"));
    try testing.expect(!match("ab", "c*"));
    try testing.expect(!match("ab", "*c"));
    try testing.expect(!match("ab", "ac"));
    try testing.expect(!match("ab", "*ac*"));
    try testing.expect(!match("ab", "ac*"));
    try testing.expect(!match("ab", "*ac"));

    try testing.expect(match("abc", "*"));
    try testing.expect(match("abc", "*a*"));
    try testing.expect(match("abc", "*b*"));
    try testing.expect(match("abc", "*c*"));
    try testing.expect(match("abc", "a*"));
    try testing.expect(match("abc", "*c"));
    try testing.expect(match("abc", "*ab*"));
    try testing.expect(match("abc", "ab*"));
    try testing.expect(match("abc", "*bc*"));
    try testing.expect(match("abc", "*bc"));
    try testing.expect(match("abc", "*abc*"));
    try testing.expect(match("abc", "abc*"));
    try testing.expect(match("abc", "*abc"));
    try testing.expect(match("abc", "abc"));

    try testing.expect(!match("abc", "*a"));
    try testing.expect(!match("abc", "*b"));
    try testing.expect(!match("abc", "b*"));
    try testing.expect(!match("abc", "c*"));
    try testing.expect(!match("abc", "*ab"));
    try testing.expect(!match("abc", "bc*"));
    try testing.expect(!match("abc", "*d*"));
    try testing.expect(!match("abc", "d*"));
    try testing.expect(!match("abc", "*d"));
}

/// Returns .lt if a is less general than b.
/// Returns .gt if a is more general than b.
/// Returns .eq if a and b are equally general.
/// Both a and b must be valid globs, see `validate()`.
pub fn order(a: []const u8, b: []const u8) std.math.Order {
    if (std.debug.runtime_safety) {
        validate(a) catch unreachable;
        validate(b) catch unreachable;
    }

    if (mem.eql(u8, a, "*") and mem.eql(u8, b, "*")) {
        return .eq;
    } else if (mem.eql(u8, a, "*")) {
        return .gt;
    } else if (mem.eql(u8, b, "*")) {
        return .lt;
    }

    const count_a = @as(u2, @intFromBool(a[0] == '*')) + @intFromBool(a[a.len - 1] == '*');
    const count_b = @as(u2, @intFromBool(b[0] == '*')) + @intFromBool(b[b.len - 1] == '*');

    if (count_a == 0 and count_b == 0) {
        return .eq;
    } else if (count_a == count_b) {
        // This may look backwards since e.g. "c*" is more general than "cc*"
        return std.math.order(b.len, a.len);
    } else {
        return std.math.order(count_a, count_b);
    }
}

test order {
    const testing = std.testing;
    const Order = std.math.Order;

    try testing.expectEqual(Order.eq, order("*", "*"));
    try testing.expectEqual(Order.eq, order("*a*", "*b*"));
    try testing.expectEqual(Order.eq, order("a*", "*b"));
    try testing.expectEqual(Order.eq, order("*a", "*b"));
    try testing.expectEqual(Order.eq, order("*a", "b*"));
    try testing.expectEqual(Order.eq, order("a*", "b*"));

    const descending = [_][]const u8{
        "*",
        "*a*",
        "*b*",
        "*a*",
        "*ab*",
        "*bab*",
        "*a",
        "b*",
        "*b",
        "*a",
        "a",
        "bababab",
        "b",
        "a",
    };

    for (descending, 0..) |a, i| {
        for (descending[i..]) |b| {
            try testing.expect(order(a, b) != .lt);
        }
    }

    var ascending = descending;
    mem.reverse([]const u8, &ascending);

    for (ascending, 0..) |a, i| {
        for (ascending[i..]) |b| {
            try testing.expect(order(a, b) != .gt);
        }
    }
}
