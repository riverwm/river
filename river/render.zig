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
const os = std.os;

const server = &@import("main.zig").server;

const Output = @import("Output.zig");

const log = std.log.scoped(.render);

pub fn renderOutput(output: *Output) void {
    const scene_output = server.root.scene.getSceneOutput(output.wlr_output).?;
    if (!scene_output.commit()) {
        log.err("output commit failed for {s}", .{output.wlr_output.name});
    }

    var now: os.timespec = undefined;
    os.clock_gettime(os.CLOCK.MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
    scene_output.sendFrameDone(&now);
}
