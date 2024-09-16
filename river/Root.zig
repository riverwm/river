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
layout_change: wl.Listener(*wlr.OutputLayout) = wl.Listener(*wlr.OutputLayout).init(handleLayoutChange),

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

/// A list of all outputs
all_outputs: wl.list.Head(Output, .all_link),

/// A list of all active outputs (any one that can be interacted with, even if
/// it's turned off by dpms)
active_outputs: wl.list.Head(Output, .active_link),

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
        .all_outputs = undefined,
        .active_outputs = undefined,

        .presentation = try wlr.Presentation.create(server.wl_server, server.backend),
        .xdg_output_manager = try wlr.XdgOutputManagerV1.create(server.wl_server, output_layout),
        .output_manager = try wlr.OutputManagerV1.create(server.wl_server),
        .power_manager = try wlr.OutputPowerManagerV1.create(server.wl_server),
        .gamma_control_manager = try wlr.GammaControlManagerV1.create(server.wl_server),
    };

    root.all_outputs.init();
    root.active_outputs.init();

    server.backend.events.new_output.add(&root.new_output);
    root.output_manager.events.apply.add(&root.manager_apply);
    root.output_manager.events.@"test".add(&root.manager_test);
    root.output_layout.events.change.add(&root.layout_change);
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

pub fn layerSurfaceTree(root: Root, layer: zwlr.LayerShellV1.Layer) *wlr.SceneTree {
    const trees = [_]*wlr.SceneTree{
        root.layers.background,
        root.layers.bottom,
        root.layers.top,
        root.layers.overlay,
    };
    return trees[@intCast(@intFromEnum(layer))];
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

    server.root.handleOutputConfigChange() catch log.err("out of memory", .{});

    server.input_manager.reconfigureDevices();
}

/// Remove the output from root.active_outputs and the output layout.
/// Evacuate windows if necessary.
pub fn deactivateOutput(root: *Root, output: *Output) void {
    {
        // If the output has already been removed, do nothing
        var it = root.active_outputs.iterator(.forward);
        while (it.next()) |o| {
            if (o == output) break;
        } else return;
    }

    root.output_layout.remove(output.wlr_output);

    output.active_link.remove();
    output.active_link.init();

    // XXX Close all layer surfaces on the removed output

    // We must call reconfigureDevices here to unmap devices that might be mapped to this output
    // in order to prevent a segfault in wlroots.
    server.input_manager.reconfigureDevices();
}

/// Add the output to root.active_outputs and the output layout if it has not
/// already been added.
pub fn activateOutput(root: *Root, output: *Output) void {
    {
        // If we have already added the output, do nothing and return
        var it = root.active_outputs.iterator(.forward);
        while (it.next()) |o| if (o == output) return;
    }

    root.active_outputs.append(output);

    // This arranges outputs from left-to-right in the order they appear. The
    // wlr-output-management protocol may be used to modify this arrangement.
    // This also creates a wl_output global which is advertised to clients.
    _ = root.output_layout.addAuto(output.wlr_output) catch {
        // This would currently be very awkward to handle well and this output
        // handling code needs to be heavily refactored soon anyways for double
        // buffered state application as part of the transaction system.
        // In any case, wlroots 0.16 would have crashed here, the error is only
        // possible to handle after updating to 0.17.
        @panic("TODO handle allocation failure here");
    };
}

// We need this listener to deal with outputs that have their position auto-configured
// by the wlr_output_layout.
fn handleLayoutChange(listener: *wl.Listener(*wlr.OutputLayout), _: *wlr.OutputLayout) void {
    const root: *Root = @fieldParentPtr("layout_change", listener);

    root.handleOutputConfigChange() catch std.log.err("out of memory", .{});
}

/// Sync up the output scene node state with the output_layout and
/// send the current output configuration to all wlr-output-manager clients.
pub fn handleOutputConfigChange(root: *Root) !void {
    const config = try wlr.OutputConfigurationV1.create();
    // this destroys all associated config heads as well
    errdefer config.destroy();

    var it = root.all_outputs.iterator(.forward);
    while (it.next()) |output| {
        // If the output is not part of the layout (and thus disabled)
        // the box will be zeroed out.
        var box: wlr.Box = undefined;
        root.output_layout.getBox(output.wlr_output, &box);

        // XXX
        //output.tree.node.setEnabled(!box.empty());
        //output.tree.node.setPosition(box.x, box.y);
        //output.scene_output.setPosition(box.x, box.y);

        const head = try wlr.OutputConfigurationV1.Head.create(config, output.wlr_output);
        head.state.x = box.x;
        head.state.y = box.y;
    }

    root.output_manager.setConfiguration(config);
}

fn handleManagerApply(
    listener: *wl.Listener(*wlr.OutputConfigurationV1),
    config: *wlr.OutputConfigurationV1,
) void {
    const root: *Root = @fieldParentPtr("manager_apply", listener);
    defer config.destroy();

    std.log.scoped(.output_manager).info("applying output configuration", .{});

    root.processOutputConfig(config, .apply);

    root.handleOutputConfigChange() catch std.log.err("out of memory", .{});
}

fn handleManagerTest(
    listener: *wl.Listener(*wlr.OutputConfigurationV1),
    config: *wlr.OutputConfigurationV1,
) void {
    const root: *Root = @fieldParentPtr("manager_test", listener);
    defer config.destroy();

    root.processOutputConfig(config, .test_only);
}

fn processOutputConfig(
    root: *Root,
    config: *wlr.OutputConfigurationV1,
    action: enum { test_only, apply },
) void {
    // Ignore layout change events this function generates while applying the config
    root.layout_change.link.remove();
    defer root.output_layout.events.change.add(&root.layout_change);

    var success = true;

    var it = config.heads.iterator(.forward);
    while (it.next()) |head| {
        const wlr_output = head.state.output;
        const output: *Output = @ptrFromInt(wlr_output.data);

        var proposed_state = wlr.Output.State.init();
        head.state.apply(&proposed_state);

        // Negative output coordinates currently cause Xwayland clients to not receive click events.
        // See: https://gitlab.freedesktop.org/xorg/xserver/-/issues/899
        if (build_options.xwayland and server.xwayland != null and
            (head.state.x < 0 or head.state.y < 0))
        {
            std.log.scoped(.output_manager).err(
                \\Attempted to set negative coordinates for output {s}.
                \\Negative output coordinates are disallowed if Xwayland is enabled due to a limitation of Xwayland.
            , .{output.wlr_output.name});
            success = false;
            continue;
        }

        switch (action) {
            .test_only => {
                if (!wlr_output.testState(&proposed_state)) success = false;
            },
            .apply => {
                output.applyState(&proposed_state) catch {
                    std.log.scoped(.output_manager).err("failed to apply config to output {s}", .{
                        output.wlr_output.name,
                    });
                    success = false;
                };
                if (output.wlr_output.enabled) {
                    // applyState() will always add the output to the layout on success, which means
                    // that this function cannot fail as it does not need to allocate a new layout output.
                    _ = root.output_layout.add(output.wlr_output, head.state.x, head.state.y) catch unreachable;
                }
            },
        }
    }

    if (action == .apply) server.wm.dirtyPending();

    if (success) {
        config.sendSucceeded();
    } else {
        config.sendFailed();
    }
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

    const requested = event.mode == .on;

    if (output.wlr_output.enabled == requested) {
        std.log.debug("output {s} dpms is already {s}, ignoring request", .{
            event.output.name,
            @tagName(event.mode),
        });
        return;
    }

    {
        var state = wlr.Output.State.init();
        defer state.finish();

        state.setEnabled(requested);

        if (!output.wlr_output.commitState(&state)) {
            std.log.scoped(.server).err("output commit failed for {s}", .{output.wlr_output.name});
            return;
        }
    }

    output.updateLockRenderStateOnEnableDisable();
    output.gamma_dirty = true;
}

fn handleSetGamma(
    _: *wl.Listener(*wlr.GammaControlManagerV1.event.SetGamma),
    event: *wlr.GammaControlManagerV1.event.SetGamma,
) void {
    // The output may have been destroyed, in which case there is nothing to do
    const output = @as(?*Output, @ptrFromInt(event.output.data)) orelse return;

    std.log.debug("client requested to set gamma", .{});

    output.gamma_dirty = true;
    output.wlr_output.scheduleFrame();
}
