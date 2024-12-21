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

const Root = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const zwlr = @import("wayland").server.zwlr;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const DragIcon = @import("DragIcon.zig");
const LockSurface = @import("LockSurface.zig");
const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Window = @import("Window.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");

scene: *wlr.Scene,
/// All windows, status bars, drowdown menus, etc. that can recieve pointer events and similar.
interactive_tree: *wlr.SceneTree,
/// Drag icons, which cannot recieve e.g. pointer events and are therefore kept
/// in a separate tree from the interactive tree.
drag_icons: *wlr.SceneTree,
/// Always disabled, used for staging changes
/// TODO can this be refactored away?
hidden_tree: *wlr.SceneTree,
/// Direct child of interactive_tree, disabled when the session is locked
normal_tree: *wlr.SceneTree,
/// Direct child of interactive_tree, enabled when the session is locked
locked_tree: *wlr.SceneTree,

/// All direct children of the normal_tree scene node
layers: struct {
    /// Background layer shell layer
    background: *wlr.SceneTree,
    /// Bottom layer shell layer
    bottom: *wlr.SceneTree,
    /// Windows and shell surfaces of the window manager
    wm: *wlr.SceneTree,
    /// Top layer shell layer
    top: *wlr.SceneTree,
    /// Overlay layer shell layer
    overlay: *wlr.SceneTree,
    /// Popups from xdg-shell and input-method-v2 clients
    popups: *wlr.SceneTree,
    /// Xwayland override redirect windows are a legacy wart that decide where
    /// to place themselves in layout coordinates. Unfortunately this is how
    /// X11 decided to make dropdown menus and the like possible.
    override_redirect: if (build_options.xwayland) *wlr.SceneTree else void,
},

new_output: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleNewOutput),

output_layout: *wlr.OutputLayout,

presentation: *wlr.Presentation,
xdg_output_manager: *wlr.XdgOutputManagerV1,

output_manager: *wlr.OutputManagerV1,
manager_apply: wl.Listener(*wlr.OutputConfigurationV1) =
    wl.Listener(*wlr.OutputConfigurationV1).init(handleManagerApply),
manager_test: wl.Listener(*wlr.OutputConfigurationV1) =
    wl.Listener(*wlr.OutputConfigurationV1).init(handleManagerTest),

power_manager: *wlr.OutputPowerManagerV1,
power_manager_set_mode: wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode) =
    wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode).init(handlePowerManagerSetMode),

gamma_control_manager: *wlr.GammaControlManagerV1,
gamma_control_set_gamma: wl.Listener(*wlr.GammaControlManagerV1.event.SetGamma) =
    wl.Listener(*wlr.GammaControlManagerV1.event.SetGamma).init(handleSetGamma),

/// All Outputs that have a corresponding wlr_output.
outputs: wl.list.Head(Output, .link),

pub fn init(root: *Root) !void {
    const output_layout = try wlr.OutputLayout.create(server.wl_server);
    errdefer output_layout.destroy();

    const scene = try wlr.Scene.create();
    errdefer scene.tree.node.destroy();

    const interactive_tree = try scene.tree.createSceneTree();
    const drag_icons = try scene.tree.createSceneTree();
    const hidden_tree = try scene.tree.createSceneTree();
    hidden_tree.node.setEnabled(false);

    const normal_tree = try interactive_tree.createSceneTree();
    const locked_tree = try interactive_tree.createSceneTree();

    root.* = .{
        .scene = scene,
        .interactive_tree = interactive_tree,
        .drag_icons = drag_icons,
        .hidden_tree = hidden_tree,
        .normal_tree = normal_tree,
        .locked_tree = locked_tree,
        .layers = .{
            .background = try normal_tree.createSceneTree(),
            .bottom = try normal_tree.createSceneTree(),
            .wm = try normal_tree.createSceneTree(),
            .top = try normal_tree.createSceneTree(),
            .overlay = try normal_tree.createSceneTree(),
            .popups = try normal_tree.createSceneTree(),
            .override_redirect = if (build_options.xwayland) try normal_tree.createSceneTree(),
        },
        .output_layout = output_layout,
        .outputs = undefined,

        .presentation = try wlr.Presentation.create(server.wl_server, server.backend),
        .xdg_output_manager = try wlr.XdgOutputManagerV1.create(server.wl_server, output_layout),
        .output_manager = try wlr.OutputManagerV1.create(server.wl_server),
        .power_manager = try wlr.OutputPowerManagerV1.create(server.wl_server),
        .gamma_control_manager = try wlr.GammaControlManagerV1.create(server.wl_server),
    };

    root.outputs.init();

    server.backend.events.new_output.add(&root.new_output);
    root.output_manager.events.apply.add(&root.manager_apply);
    root.output_manager.events.@"test".add(&root.manager_test);
    root.power_manager.events.set_mode.add(&root.power_manager_set_mode);
    root.gamma_control_manager.events.set_gamma.add(&root.gamma_control_set_gamma);
}

pub fn deinit(root: *Root) void {
    root.output_layout.destroy();
}

pub const AtResult = struct {
    node: *wlr.SceneNode,
    surface: ?*wlr.Surface,
    sx: f64,
    sy: f64,
    data: SceneNodeData.Data,
};

/// Return information about what is currently rendered in the interactive_tree
/// tree at the given layout coordinates, taking surface input regions into account.
pub fn at(root: Root, lx: f64, ly: f64) ?AtResult {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    const node = root.interactive_tree.node.at(lx, ly, &sx, &sy) orelse return null;

    const surface: ?*wlr.Surface = blk: {
        if (node.type == .buffer) {
            const scene_buffer = wlr.SceneBuffer.fromNode(node);
            if (wlr.SceneSurface.tryFromBuffer(scene_buffer)) |scene_surface| {
                break :blk scene_surface.surface;
            }
        }
        break :blk null;
    };

    if (SceneNodeData.fromNode(node)) |scene_node_data| {
        return .{
            .node = node,
            .surface = surface,
            .sx = sx,
            .sy = sy,
            .data = scene_node_data.data,
        };
    } else {
        return null;
    }
}

fn handleNewOutput(_: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const log = std.log.scoped(.output_manager);

    log.debug("new output {s}", .{wlr_output.name});

    Output.create(wlr_output) catch |err| {
        switch (err) {
            error.OutOfMemory => log.err("out of memory", .{}),
            error.InitRenderFailed => log.err("failed to initialize renderer for output {s}", .{wlr_output.name}),
        }
        wlr_output.destroy();
        return;
    };
}

fn handleManagerTest(_: *wl.Listener(*wlr.OutputConfigurationV1), config: *wlr.OutputConfigurationV1) void {
    defer config.destroy();

    if (!validateConfigCoordinates(config)) {
        config.sendFailed();
        return;
    }

    const states = config.buildState() catch {
        std.log.err("out of memory", .{});
        config.sendFailed();
        return;
    };
    defer std.c.free(states.ptr);

    var swapchain_manager: wlr.OutputSwapchainManager = undefined;
    swapchain_manager.init(server.backend);
    defer swapchain_manager.finish();

    if (swapchain_manager.prepare(states)) {
        config.sendSucceeded();
    } else {
        config.sendFailed();
    }
}

fn handleManagerApply(_: *wl.Listener(*wlr.OutputConfigurationV1), config: *wlr.OutputConfigurationV1) void {
    std.log.scoped(.output_manager).info("applying output configuration", .{});

    if (!validateConfigCoordinates(config)) {
        config.sendFailed();
        return;
    }

    var it = config.heads.iterator(.forward);
    while (it.next()) |head| {
        const output: *Output = @ptrFromInt(head.state.output.data);

        const prev_state = output.pending.state;

        output.pending = .{
            .state = if (head.state.enabled) .enabled else .disabled_hard,
            .mode = blk: {
                if (head.state.mode) |mode| {
                    break :blk .{ .standard = mode };
                } else {
                    break :blk .{ .custom = .{
                        .width = head.state.custom_mode.width,
                        .height = head.state.custom_mode.height,
                        .refresh = head.state.custom_mode.refresh,
                    } };
                }
            },
            .x = head.state.x,
            .y = head.state.y,
            .transform = head.state.transform,
            .adaptive_sync = head.state.adaptive_sync_enabled,
            .auto_layout = false,
        };

        if (output.pending.state == .enabled and prev_state != .enabled) {
            output.link_pending.remove();
            server.wm.pending.outputs.append(output);
        }
    }

    if (server.wm.pending.output_config) |old| {
        old.sendFailed();
        old.destroy();
    }
    server.wm.pending.output_config = config;

    server.wm.dirtyPending();
}

fn validateConfigCoordinates(config: *wlr.OutputConfigurationV1) bool {
    var it = config.heads.iterator(.forward);
    while (it.next()) |head| {
        // Negative output coordinates currently cause Xwayland clients to not receive click events.
        // See: https://gitlab.freedesktop.org/xorg/xserver/-/issues/899
        if (build_options.xwayland and server.xwayland != null and
            (head.state.x < 0 or head.state.y < 0))
        {
            std.log.scoped(.output_manager).err(
                \\Attempted to set negative coordinates for output {s}.
                \\Negative output coordinates are disallowed if Xwayland is enabled due to a limitation of Xwayland.
            , .{head.state.output.name});
            return false;
        }
    }
    return true;
}

fn handlePowerManagerSetMode(
    _: *wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode),
    event: *wlr.OutputPowerManagerV1.event.SetMode,
) void {
    // The output may have been destroyed, in which case there is nothing to do
    const output = @as(?*Output, @ptrFromInt(event.output.data)) orelse return;

    std.log.debug("client requested dpms {s} for output {s}", .{
        @tagName(event.mode),
        event.output.name,
    });

    switch (output.pending.state) {
        .enabled => {
            if (event.mode == .off) output.pending.state = .disabled_soft else return;
        },
        .disabled_soft => {
            if (event.mode == .on) output.pending.state = .enabled else return;
        },
        .disabled_hard, .destroying => unreachable,
    }

    server.wm.dirtyPending();
}

fn handleSetGamma(
    _: *wl.Listener(*wlr.GammaControlManagerV1.event.SetGamma),
    event: *wlr.GammaControlManagerV1.event.SetGamma,
) void {
    // The output may have been destroyed, in which case there is nothing to do
    const output = @as(?*Output, @ptrFromInt(event.output.data)) orelse return;

    std.log.debug("client requested to set gamma", .{});

    output.gamma_dirty = true;
    event.output.scheduleFrame();
}

pub fn commitOutputState(root: *Root) void {
    const wm = &server.wm;

    {
        var it = wm.sent.outputs.iterator(.forward);
        while (it.next()) |output| {
            const wlr_output = output.wlr_output orelse continue;
            switch (output.sent.state) {
                .enabled, .disabled_soft => {
                    output.scene_output.?.setPosition(output.sent.x, output.sent.y);
                    _ = root.output_layout.add(wlr_output, output.sent.x, output.sent.y) catch {
                        std.log.err("out of memory", .{});
                        continue; // Try again next time
                    };
                },
                .disabled_hard, .destroying => {
                    root.output_layout.remove(wlr_output);
                },
            }
        }
    }

    server.input_manager.reconfigureDevices();

    const need_modeset = blk: {
        var it = wm.sent.outputs.iterator(.forward);
        while (it.next()) |output| {
            const wlr_output = output.wlr_output orelse continue;

            switch (output.sent.state) {
                .enabled => if (!wlr_output.enabled) break :blk true,
                .disabled_soft, .disabled_hard, .destroying => continue,
            }

            switch (output.sent.mode) {
                .standard => |mode| {
                    if (mode != wlr_output.current_mode) break :blk true;
                },
                .custom => |mode| {
                    if (mode.width != wlr_output.width) break :blk true;
                    if (mode.height != wlr_output.height) break :blk true;
                    if (mode.refresh != wlr_output.refresh) break :blk true;
                },
                .none => {},
            }
            if (output.sent.adaptive_sync != (wlr_output.adaptive_sync_status == .enabled)) {
                break :blk true;
            }
        }

        break :blk false;
    };

    if (need_modeset) {
        var states = std.ArrayList(wlr.Backend.OutputState).init(util.gpa);
        defer states.deinit();
        defer for (states.items) |*s| s.base.finish();

        {
            var it = wm.sent.outputs.iterator(.forward);
            while (it.next()) |output| {
                const wlr_output = output.wlr_output orelse continue;
                const state = states.addOne() catch {
                    std.log.err("out of memory", .{});
                    return;
                };

                state.output = wlr_output;
                state.base = wlr.Output.State.init();

                output.sent.apply(&state.base);
            }
        }

        var swapchain_manager: wlr.OutputSwapchainManager = undefined;
        swapchain_manager.init(server.backend);
        defer swapchain_manager.finish();

        if (!swapchain_manager.prepare(states.items)) {
            std.log.err("failed to prepare new output configuration", .{});
            // TODO search for a working fallback

            if (wm.sent.output_config) |config| {
                config.sendFailed();
                config.destroy();
                wm.sent.output_config = null;
            }

            {
                // Revert to last working state on failure
                var it = wm.sent.outputs.iterator(.forward);
                while (it.next()) |output| {
                    output.pending = output.current;
                    output.sent = output.current;
                }
                wm.dirtyPending();
            }
            return;
        }

        for (states.items) |*state| {
            const output: *Output = @ptrFromInt(state.output.data);
            if (!output.scene_output.?.buildState(&state.base, &.{
                .swapchain = swapchain_manager.getSwapchain(state.output),
            })) {
                std.log.err("failed to render scene for {s}", .{state.output.name});
            }
        }

        if (!server.backend.commit(states.items)) {
            std.log.err("failed to commit new output configuration", .{});

            if (wm.sent.output_config) |config| {
                config.sendFailed();
                config.destroy();
                wm.sent.output_config = null;
            }

            {
                // Revert to last working state on failure
                var it = wm.sent.outputs.iterator(.forward);
                while (it.next()) |output| {
                    output.pending = output.current;
                    output.sent = output.current;
                }
                wm.dirtyPending();
            }
            return;
        }

        swapchain_manager.apply();
    }

    if (wm.sent.output_config) |config| {
        config.sendSucceeded();
        config.destroy();
        wm.sent.output_config = null;
    }

    {
        var it = wm.sent.outputs.iterator(.forward);
        while (it.next()) |output| {
            output.current = output.sent;

            if (output.wlr_output) |wlr_output| {
                wlr_output.scheduleFrame();
            }
        }
    }

    // XXX sending this every transaction is too noisy
    root.sendManagerConfig() catch {
        std.log.err("out of memory", .{});
    };
}

/// Send the current output state to all wlr-output-manager clients.
fn sendManagerConfig(root: *Root) !void {
    const config = try wlr.OutputConfigurationV1.create();
    // this destroys all associated config heads as well
    errdefer config.destroy();

    var it = root.outputs.iterator(.forward);
    while (it.next()) |output| {
        const head = try wlr.OutputConfigurationV1.Head.create(config, output.wlr_output.?);

        // It's only necessary to overwrite the state that does not require a modeset.
        // All state that requires a modeset will have already been committed to the wlr_output.
        head.state.enabled = switch (output.current.state) {
            .enabled, .disabled_soft => true,
            .disabled_hard => false,
            .destroying => unreachable,
        };
        head.state.scale = output.current.scale;
        head.state.transform = output.current.transform;
        head.state.x = output.current.x;
        head.state.y = output.current.y;
    }

    root.output_manager.setConfiguration(config);
}
