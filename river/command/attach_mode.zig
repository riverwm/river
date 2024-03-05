// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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
const mem = std.mem;
const meta = std.meta;

const server = &@import("../main.zig").server;

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");
const Config = @import("../Config.zig");

fn parseAttachMode(args: []const [:0]const u8) Error!Config.AttachMode {
    if (args.len < 2) return Error.NotEnoughArguments;

    const tag = meta.stringToEnum(meta.Tag(Config.AttachMode), args[1]) orelse return Error.UnknownOption;
    switch (tag) {
        inline .top, .bottom, .above, .below => |mode| {
            if (args.len > 2) return Error.TooManyArguments;

            return mode;
        },
        .after => {
            if (args.len < 3) return Error.NotEnoughArguments;
            if (args.len > 3) return Error.TooManyArguments;

            return .{ .after = try std.fmt.parseInt(u32, args[2], 10) };
        },
    }
}

pub fn outputAttachMode(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    const output = seat.focused_output orelse return;
    output.attach_mode = try parseAttachMode(args);
}

pub fn defaultAttachMode(
    _: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    server.config.default_attach_mode = try parseAttachMode(args);
}
