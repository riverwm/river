// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2023 The River Developers
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

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const globber = @import("globber");
const util = @import("util.zig");

const View = @import("View.zig");

pub const RuleGlobs = struct {
    app_id_glob: []const u8,
    title_glob: []const u8,
};

pub const MaxGlobLen = struct {
    app_id: usize,
    title: usize,
};

pub fn RuleList(comptime T: type) type {
    return struct {
        const List = @This();

        const Rule = struct {
            app_id_glob: []const u8,
            title_glob: []const u8,
            value: T,
        };

        /// Ordered from most specific to most general.
        /// Ordered first by app-id generality then by title generality.
        rules: std.ArrayListUnmanaged(Rule) = .{},

        pub fn deinit(list: *List) void {
            for (list.rules.items) |rule| {
                util.gpa.free(rule.app_id_glob);
                util.gpa.free(rule.title_glob);
            }
            list.rules.deinit(util.gpa);
        }

        pub fn add(list: *List, rule: Rule) error{OutOfMemory}!void {
            const index = for (list.rules.items, 0..) |*existing, i| {
                if (mem.eql(u8, rule.app_id_glob, existing.app_id_glob) and
                    mem.eql(u8, rule.title_glob, existing.title_glob))
                {
                    existing.value = rule.value;
                    return;
                }

                switch (globber.order(rule.app_id_glob, existing.app_id_glob)) {
                    .lt => break i,
                    .eq => {
                        if (globber.order(rule.title_glob, existing.title_glob) == .lt) {
                            break i;
                        }
                    },
                    .gt => {},
                }
            } else list.rules.items.len;

            const owned_app_id_glob = try util.gpa.dupe(u8, rule.app_id_glob);
            errdefer util.gpa.free(owned_app_id_glob);

            const owned_title_glob = try util.gpa.dupe(u8, rule.title_glob);
            errdefer util.gpa.free(owned_title_glob);

            try list.rules.insert(util.gpa, index, .{
                .app_id_glob = owned_app_id_glob,
                .title_glob = owned_title_glob,
                .value = rule.value,
            });
        }

        pub fn del(list: *List, rule: RuleGlobs) ?T {
            for (list.rules.items, 0..) |existing, i| {
                if (mem.eql(u8, rule.app_id_glob, existing.app_id_glob) and
                    mem.eql(u8, rule.title_glob, existing.title_glob))
                {
                    util.gpa.free(existing.app_id_glob);
                    util.gpa.free(existing.title_glob);
                    return list.rules.orderedRemove(i).value;
                }
            }
            return null;
        }

        /// Returns the value of the most specific rule matching the view.
        /// Returns null if no rule matches.
        pub fn match(list: *List, view: *View) ?T {
            assert(!view.destroying);
            const app_id = mem.sliceTo(view.getAppId(), 0) orelse "";
            const title = mem.sliceTo(view.getTitle(), 0) orelse "";

            for (list.rules.items) |rule| {
                if (globber.match(app_id, rule.app_id_glob) and
                    globber.match(title, rule.title_glob))
                {
                    return rule.value;
                }
            }

            return null;
        }

        /// Returns the length of the longest globs.
        pub fn getMaxGlobLen(list: *const List) MaxGlobLen {
            var app_id_len: usize = 0;
            var title_len: usize = 0;
            for (list.rules.items) |rule| {
                app_id_len = @max(app_id_len, rule.app_id_glob.len);
                title_len = @max(title_len, rule.title_glob.len);
            }
            return .{
                .app_id = app_id_len,
                .title = title_len,
            };
        }
    };
}
