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

// Minimum effective width/height for outputs.
// This is needed, to prevent integer overflows caused by the output effective
// resolution beeing too small to fit clients that can't get scaled more and
// thus will be bigger than the output resolution.
// The value is totally arbitrary and low enough, that it should never be
// encountered during normal usage.
const min_size = 50;

root: *Root,

listen_new_output: c.wl_listener = undefined,
listen_output_layout_change: c.wl_listener = undefined,

wlr_output_manager: *c.wlr_output_manager_v1,
listen_output_manager_apply: c.wl_listener = undefined,
listen_output_manager_test: c.wl_listener = undefined,

wlr_output_power_manager: *c.wlr_output_power_manager_v1,
listen_output_power_manager_set_mode: c.wl_listener = undefined,

/// True if and only if we are currently applying an output config
output_config_pending: bool = false,

pub fn init(self: *Self, server: *Server) !void {
    self.* = .{
        .wlr_output_manager = c.wlr_output_manager_v1_create(server.wl_display) orelse
            return error.OutOfMemory,
        .wlr_output_power_manager = c.wlr_output_power_manager_v1_create(server.wl_display) orelse
            return error.OutOfMemory,
        .root = &server.root,
    };

    self.listen_new_output.notify = handleNewOutput;
    c.wl_signal_add(&server.wlr_backend.events.new_output, &self.listen_new_output);

    // Set up wlr_output_management
    self.listen_output_manager_apply.notify = handleOutputManagerApply;
    c.wl_signal_add(&self.wlr_output_manager.events.apply, &self.listen_output_manager_apply);
    self.listen_output_manager_test.notify = handleOutputManagerTest;
    c.wl_signal_add(&self.wlr_output_manager.events.@"test", &self.listen_output_manager_test);

    // Listen for changes in the output layout to send them to the clients of wlr_output_manager
    self.listen_output_layout_change.notify = handleOutputLayoutChange;
    c.wl_signal_add(&self.root.wlr_output_layout.events.change, &self.listen_output_layout_change);

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
    const ptr_node = util.gpa.create(std.TailQueue(*Output).Node) catch {
        util.gpa.destroy(node);
        c.wlr_output_destroy(wlr_output);
        return;
    };
    ptr_node.data = &node.data;

    self.root.all_outputs.append(ptr_node);
    self.root.addOutput(node);
}

/// Sends the new output configuration to all clients of wlr_output_manager
fn handleOutputLayoutChange(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_output_layout_change", listener.?);
    // Dont do anything if the layout change is coming from applying a config
    if (self.output_config_pending) return;

    const config = self.createOutputConfigurationFromCurrent() catch {
        log.err(.output_manager, "Could not create output configuration", .{});
        return;
    };
    c.wlr_output_manager_v1_set_configuration(self.wlr_output_manager, config);
}

fn handleOutputManagerApply(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_output_manager_apply", listener.?);
    const config = util.voidCast(c.wlr_output_configuration_v1, data.?);
    defer c.wlr_output_configuration_v1_destroy(config);

    if (self.applyOutputConfig(config)) {
        c.wlr_output_configuration_v1_send_succeeded(config);
    } else {
        c.wlr_output_configuration_v1_send_failed(config);
    }

    // Now send the config that actually was applied
    const actualConfig = self.createOutputConfigurationFromCurrent() catch {
        log.err(.output_manager, "Could not create output configuration", .{});
        return;
    };
    c.wlr_output_manager_v1_set_configuration(self.wlr_output_manager, actualConfig);
}

fn handleOutputManagerTest(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_output_manager_test", listener.?);
    const config = util.voidCast(c.wlr_output_configuration_v1, data.?);
    defer c.wlr_output_configuration_v1_destroy(config);

    if (testOutputConfig(config, true)) {
        c.wlr_output_configuration_v1_send_succeeded(config);
    } else {
        c.wlr_output_configuration_v1_send_failed(config);
    }
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
        .{ log_text, wlr_output.name },
    );

    c.wlr_output_enable(wlr_output, enable);
    if (!c.wlr_output_commit(wlr_output)) {
        log.err(
            .output_manager,
            "wlr_output_commit failed for {}",
            .{wlr_output.name},
        );
    }
}

/// Applies an output config
fn applyOutputConfig(self: *Self, config: *c.wlr_output_configuration_v1) bool {
    // We need to store whether a config is pending because we listen to wlr_output_layout.change
    // and this event can be triggered by applying the config
    self.output_config_pending = true;
    defer self.output_config_pending = false;

    // Test if the config should apply cleanly
    if (!testOutputConfig(config, false)) return false;

    const list_head: *c.wl_list = &config.heads;
    var it: *c.wl_list = list_head.next;
    while (it != list_head) : (it = it.next) {
        const head = @fieldParentPtr(c.wlr_output_configuration_head_v1, "link", it);
        const output = util.voidCast(Output, @as(*c.wlr_output, head.state.output).data.?);
        const disable = output.wlr_output.enabled and !head.state.enabled;

        // This commit will only fail due to runtime errors.
        // We choose to ignore this error
        if (!c.wlr_output_commit(output.wlr_output)) {
            log.err(.output_manager, "wlr_output_commit failed for {}", .{output.wlr_output.name});
        }

        if (output.wlr_output.enabled) {
            // Moves the output if it is already in the layout
            c.wlr_output_layout_add(self.root.wlr_output_layout, output.wlr_output, head.state.x, head.state.y);
        }

        if (disable) {
            const node = @fieldParentPtr(std.TailQueue(Output).Node, "data", output);
            self.root.removeOutput(node);
            c.wlr_output_layout_remove(self.root.wlr_output_layout, output.wlr_output);
        }
        // Arrange layers to adjust the usable_box
        // We dont need to call arrangeViews() since arrangeLayers() will call
        // it for us because the usable_box changed
        output.arrangeLayers();
        self.root.startTransaction();
    }

    return true;
}

/// Tests the output configuration.
/// If rollback is false all changes are applied to the pending state of the affected outputs.
fn testOutputConfig(config: *c.wlr_output_configuration_v1, rollback: bool) bool {
    var ok = true;
    const list_head: *c.wl_list = &config.heads;
    var it: *c.wl_list = list_head.next;
    while (it != list_head) : (it = it.next) {
        const head = @fieldParentPtr(c.wlr_output_configuration_head_v1, "link", it);
        const wlr_output = @as(*c.wlr_output, head.state.output);

        const width = if (@as(?*c.wlr_output_mode, head.state.mode)) |m| m.width else head.state.custom_mode.width;
        const height = if (@as(?*c.wlr_output_mode, head.state.mode)) |m| m.height else head.state.custom_mode.height;
        const scale = head.state.scale;

        const too_small = (@intToFloat(f32, width) / scale < min_size) or
            (@intToFloat(f32, height) / scale < min_size);

        if (too_small) {
            log.info(
                .output_manager,
                "The requested output resolution {}x{} scaled with {} for {} would be too small.",
                .{ width, height, scale, wlr_output.name },
            );
        }

        applyHeadToOutput(head, wlr_output);
        ok = ok and !too_small and c.wlr_output_test(wlr_output);
    }

    if (rollback or !ok) {
        // Rollback all changes
        it = list_head.next;
        while (it != list_head) : (it = it.next) {
            const head = @fieldParentPtr(c.wlr_output_configuration_head_v1, "link", it);
            const wlr_output = @as(*c.wlr_output, head.state.output);
            c.wlr_output_rollback(wlr_output);
        }
    }

    return ok;
}

fn applyHeadToOutput(head: *c.wlr_output_configuration_head_v1, wlr_output: *c.wlr_output) void {
    c.wlr_output_enable(wlr_output, head.state.enabled);
    // The output must be enabled for the following properties to apply
    if (head.state.enabled) {
        // TODO(wlroots) Somehow on the drm backend setting the mode causes
        // the commit in the rendering loop to fail. The commit that
        // applies the mode works fine.
        // We can just ignore this because nothing bad happens but it
        // should be fixed in the future
        // See https://github.com/swaywm/wlroots/issues/2492
        if (head.state.mode != null) {
            c.wlr_output_set_mode(wlr_output, head.state.mode);
        } else {
            const custom_mode = &head.state.custom_mode;
            c.wlr_output_set_custom_mode(wlr_output, custom_mode.width, custom_mode.height, custom_mode.refresh);
        }
        // TODO(wlroots) Figure out if this conversion is needed or if that is a bug in wlroots
        c.wlr_output_set_scale(wlr_output, @floatCast(f32, head.state.scale));
        c.wlr_output_set_transform(wlr_output, head.state.transform);
    }
}

/// Creates an wlr_output_configuration from the current configuration
fn createOutputConfigurationFromCurrent(self: *Self) !*c.wlr_output_configuration_v1 {
    var config = c.wlr_output_configuration_v1_create() orelse return error.OutOfMemory;
    errdefer c.wlr_output_configuration_v1_destroy(config);

    var it = self.root.all_outputs.first;
    while (it) |node| : (it = node.next) {
        try self.createHead(node.data, config);
    }

    return config;
}

fn createHead(self: *Self, output: *Output, config: *c.wlr_output_configuration_v1) !void {
    const wlr_output = output.wlr_output;
    const head: *c.wlr_output_configuration_head_v1 = c.wlr_output_configuration_head_v1_create(config, wlr_output) orelse
        return error.OutOfMemory;

    // If the output is not part of the layout (and thus disabled) we dont care about the position
    const box = @as(?*c.wlr_box, c.wlr_output_layout_get_box(self.root.wlr_output_layout, wlr_output));
    if (box) |b| {
        head.state.x = b.x;
        head.state.y = b.y;
    }
}
