// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2022 The River Developers
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
const os = std.os;

const xkb = @import("xkbcommon");

const c = @import("c.zig");

/// The global general-purpose allocator used throughout river's code
pub const gpa = std.heap.c_allocator;

pub fn post_fork_pre_execve() void {
    if (c.setsid() < 0) unreachable;
    if (os.system.sigprocmask(os.SIG.SETMASK, &os.empty_sigset, null) < 0) unreachable;
    const sig_dfl = os.Sigaction{
        // TODO(zig): Remove this casting after https://github.com/ziglang/zig/pull/12410
        .handler = .{ .handler = @intToPtr(?os.Sigaction.handler_fn, @ptrToInt(os.SIG.DFL)) },
        .mask = os.empty_sigset,
        .flags = 0,
    };
    os.sigaction(os.SIG.PIPE, &sig_dfl, null);
}

pub fn free_xkb_rule_names(rule_names: xkb.RuleNames) void {
    inline for (std.meta.fields(xkb.RuleNames)) |field| {
        if (@field(rule_names, field.name)) |s| gpa.free(std.mem.span(s));
    }
}
