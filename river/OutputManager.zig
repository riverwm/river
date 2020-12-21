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
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

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

new_output: wl.Listener(*wlr.Output) = undefined,

wlr_output_manager: *wlr.OutputManagerV1,
manager_apply: wl.Listener(*wlr.OutputConfigurationV1) = undefined,
manager_test: wl.Listener(*wlr.OutputConfigurationV1) = undefined,
layout_change: wl.Listener(*wlr.OutputLayout) = undefined,

power_manager: *wlr.OutputPowerManagerV1,
power_manager_set_mode: wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode) = undefined,

pub fn init(self: *Self, server: *Server) !void {
    self.* = .{
        .root = &server.root,
        .wlr_output_manager = try wlr.OutputManagerV1.create(server.wl_server),
        .power_manager = try wlr.OutputPowerManagerV1.create(server.wl_server),
    };

    self.new_output.setNotify(handleNewOutput);
    server.backend.events.new_output.add(&self.new_output);

    self.manager_apply.setNotify(handleOutputManagerApply);
    self.wlr_output_manager.events.apply.add(&self.manager_apply);

    self.manager_test.setNotify(handleOutputManagerTest);
    self.wlr_output_manager.events.@"test".add(&self.manager_test);

    self.layout_change.setNotify(handleOutputLayoutChange);
    self.root.output_layout.events.change.add(&self.layout_change);

    self.power_manager_set_mode.setNotify(handleOutputPowerManagementSetMode);
    self.power_manager.events.set_mode.add(&self.power_manager_set_mode);

    _ = try wlr.XdgOutputManagerV1.create(server.wl_server, self.root.output_layout);
}

fn handleNewOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const self = @fieldParentPtr(Self, "new_output", listener);
    log.debug(.output_manager, "new output {}", .{wlr_output.name});

    const node = util.gpa.create(std.TailQueue(Output).Node) catch {
        wlr_output.destroy();
        return;
    };
    node.data.init(self.root, wlr_output) catch {
        wlr_output.destroy();
        util.gpa.destroy(node);
        return;
    };
    const ptr_node = util.gpa.create(std.TailQueue(*Output).Node) catch {
        wlr_output.destroy();
        util.gpa.destroy(node);
        return;
    };
    ptr_node.data = &node.data;

    self.root.all_outputs.append(ptr_node);
    self.root.addOutput(&node.data);
}

/// Send the new output configuration to all wlr-output-manager clients
fn handleOutputLayoutChange(
    listener: *wl.Listener(*wlr.OutputLayout),
    output_layout: *wlr.OutputLayout,
) void {
    const self = @fieldParentPtr(Self, "layout_change", listener);

    const config = self.ouputConfigFromCurrent() catch {
        log.crit(.output_manager, "out of memory", .{});
        return;
    };
    self.wlr_output_manager.setConfiguration(config);
}

fn handleOutputManagerApply(
    listener: *wl.Listener(*wlr.OutputConfigurationV1),
    config: *wlr.OutputConfigurationV1,
) void {
    const self = @fieldParentPtr(Self, "manager_apply", listener);
    defer config.destroy();

    if (self.applyOutputConfig(config)) {
        config.sendSucceeded();
    } else {
        config.sendFailed();
    }

    // Send the config that was actually applied
    const applied_config = self.ouputConfigFromCurrent() catch {
        log.crit(.output_manager, "out of memory", .{});
        return;
    };
    self.wlr_output_manager.setConfiguration(applied_config);
}

fn handleOutputManagerTest(
    listener: *wl.Listener(*wlr.OutputConfigurationV1),
    config: *wlr.OutputConfigurationV1,
) void {
    const self = @fieldParentPtr(Self, "manager_test", listener);
    defer config.destroy();

    if (testOutputConfig(config, true)) {
        config.sendSucceeded();
    } else {
        config.sendFailed();
    }
}

fn handleOutputPowerManagementSetMode(
    listener: *wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode),
    event: *wlr.OutputPowerManagerV1.event.SetMode,
) void {
    const self = @fieldParentPtr(Self, "power_manager_set_mode", listener);

    const enable = event.mode == .on;

    const log_text = if (enable) "Enabling" else "Disabling";
    log.debug(
        .output_manager,
        "{} dpms for output {}",
        .{ log_text, event.output.name },
    );

    event.output.enable(enable);
    event.output.commit() catch
        log.err(.server, "output commit failed for {}", .{event.output.name});
}

/// Apply the given config, return false on faliure
fn applyOutputConfig(self: *Self, config: *wlr.OutputConfigurationV1) bool {
    // Ignore layout change events while applying the config
    self.layout_change.link.remove();
    defer self.root.output_layout.events.change.add(&self.layout_change);

    // Test if the config should apply cleanly
    if (!testOutputConfig(config, false)) return false;

    var it = config.heads.iterator(.forward);
    while (it.next()) |head| {
        const output = @intToPtr(*Output, head.state.output.data);
        const disable = output.wlr_output.enabled and !head.state.enabled;

        // Since we have done a successful test commit, this will only fail
        // due to error in the output's backend implementation.
        output.wlr_output.commit() catch
            log.err(.output_manager, "output commit failed for {}", .{output.wlr_output.name});

        if (output.wlr_output.enabled) {
            // Moves the output if it is already in the layout
            self.root.output_layout.add(output.wlr_output, head.state.x, head.state.y);
        }

        if (disable) {
            self.root.removeOutput(output);
            self.root.output_layout.remove(output.wlr_output);
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
fn testOutputConfig(config: *wlr.OutputConfigurationV1, rollback: bool) bool {
    var ok = true;
    var it = config.heads.iterator(.forward);
    while (it.next()) |head| {
        const wlr_output = head.state.output;

        const width = if (head.state.mode) |m| m.width else head.state.custom_mode.width;
        const height = if (head.state.mode) |m| m.height else head.state.custom_mode.height;
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
        ok = ok and !too_small and wlr_output.testCommit();
    }

    if (rollback or !ok) {
        // Rollback all changes
        it = config.heads.iterator(.forward);
        while (it.next()) |head| head.state.output.rollback();
    }

    return ok;
}

fn applyHeadToOutput(head: *wlr.OutputConfigurationV1.Head, wlr_output: *wlr.Output) void {
    wlr_output.enable(head.state.enabled);
    // The output must be enabled for the following properties to apply
    if (head.state.enabled) {
        // TODO(wlroots) Somehow on the drm backend setting the mode causes
        // the commit in the rendering loop to fail. The commit that
        // applies the mode works fine.
        // We can just ignore this because nothing bad happens but it
        // should be fixed in the future
        // See https://github.com/swaywm/wlroots/issues/2492
        if (head.state.mode) |mode| {
            wlr_output.setMode(mode);
        } else {
            log.info(.output_manager, "custom modes are not supported until the next wlroots release: ignoring", .{});
            // TODO(wlroots) uncomment the following lines when wlroots 0.13.0 is released
            // See https://github.com/swaywm/wlroots/pull/2517
            //const custom_mode = &head.state.custom_mode;
            //wlr_output.setCustomMode(custom_mode.width, custom_mode.height, custom_mode.refresh);
        }
        // TODO(wlroots) Figure out if this conversion is needed or if that is a bug in wlroots
        wlr_output.setScale(@floatCast(f32, head.state.scale));
        wlr_output.setTransform(head.state.transform);
    }
}

/// Create the config describing the current configuration
fn ouputConfigFromCurrent(self: *Self) !*wlr.OutputConfigurationV1 {
    const config = try wlr.OutputConfigurationV1.create();
    // this destroys all associated config heads as well
    errdefer config.destroy();

    var it = self.root.all_outputs.first;
    while (it) |node| : (it = node.next) try self.createHead(node.data, config);

    return config;
}

fn createHead(self: *Self, output: *Output, config: *wlr.OutputConfigurationV1) !void {
    const wlr_output = output.wlr_output;
    const head = try wlr.OutputConfigurationV1.Head.create(config, wlr_output);

    // If the output is not part of the layout (and thus disabled) we dont care
    // about the position
    if (output.root.output_layout.getBox(wlr_output)) |box| {
        head.state.x = box.x;
        head.state.y = box.y;
    }
}
