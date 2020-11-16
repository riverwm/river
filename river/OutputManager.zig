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

const build_options = @import("build_options");
const std = @import("std");

const c = @import("c.zig");
const log = @import("log.zig");
const util = @import("util.zig");

const Output = @import("Output.zig");
const Root = @import("Root.zig");
const Server = @import("Server.zig");

root: *Root,

listen_new_output: c.wl_listener = undefined,

wlr_output_power_manager: *c.wlr_output_power_manager_v1,
listen_output_power_manager_set_mode: c.wl_listener = undefined,

pub fn init(self: *Self, server: *Server) !void {
    self.* = .{
        .wlr_output_power_manager = c.wlr_output_power_manager_v1_create(server.wl_display) orelse
            return error.OutOfMemory,
        .root = &server.root,
    };

    self.listen_new_output.notify = handleNewOutput;
    c.wl_signal_add(&server.wlr_backend.events.new_output, &self.listen_new_output);

    // Set up output power manager
    self.listen_output_power_manager_set_mode.notify = handleOutputPowerManagementSetMode;
    c.wl_signal_add(&self.wlr_output_power_manager.events.set_mode, &self.listen_output_power_manager_set_mode);

    _ = c.wlr_xdg_output_manager_v1_create(server.wl_display, server.root.wlr_output_layout) orelse
        return error.OutOfMemory;
}

fn handleNewOutput(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_new_output", listener.?);
    const wlr_output = util.voidCast(c.wlr_output, data.?);
    log.debug(.output_manager, "new output {}", .{wlr_output.name});

    const node = util.gpa.create(std.TailQueue(Output).Node) catch {
        c.wlr_output_destroy(wlr_output);
        return;
    };
    node.data.init(self.root, wlr_output) catch {
        c.wlr_output_destroy(wlr_output);
        return;
    };

    self.root.addOutput(node);
}

fn handleOutputPowerManagementSetMode(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_output_power_manager_set_mode", listener.?);
    const mode_event = util.voidCast(c.wlr_output_power_v1_set_mode_event, data.?);
    const wlr_output: *c.wlr_output = mode_event.output;

    const enable = mode_event.mode == .ZWLR_OUTPUT_POWER_V1_MODE_ON;

    const log_text = if (enable) "Enabling" else "Disabling";
    log.debug(
        .output_manager,
        "{} dpms for output {}",
        .{log_text, wlr_output.name},
    );

    c.wlr_output_enable(wlr_output, enable);
    if (!c.wlr_output_commit(wlr_output)) {
        log.err(
            .server,
            "wlr_output_commit failed for {}",
            .{wlr_output.name},
        );
    }
}
