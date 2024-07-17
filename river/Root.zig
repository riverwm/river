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
const LayerSurface = @import("LayerSurface.zig");
const LockSurface = @import("LockSurface.zig");
const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Window = @import("Window.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");

scene: *wlr.Scene,
/// All windows, status bars, drowdown menus, etc. that can recieve pointer events and similar.
interactive_content: *wlr.SceneTree,
/// Drag icons, which cannot recieve e.g. pointer events and are therefore kept in a separate tree.
drag_icons: *wlr.SceneTree,

/// All direct children of the interactive_content scene node
layers: struct {
    /// Parent tree for output trees which have their position updated when
    /// outputs are moved in the layout.
    outputs: *wlr.SceneTree,
    /// Xwayland override redirect windows are a legacy wart that decide where
    /// to place themselves in layout coordinates. Unfortunately this is how
    /// X11 decided to make dropdown menus and the like possible.
    override_redirect: if (build_options.xwayland) *wlr.SceneTree else void,
},

wm: struct {
    pending: struct {
        render_list: wl.list.Head(Window, .pending_render_list_link),
    },

    inflight: struct {
        render_list: wl.list.Head(Window, .inflight_render_list_link),
    },
},

/// This is kind of like an imaginary output where windows start and end their life.
hidden: struct {
    /// This tree is always disabled.
    tree: *wlr.SceneTree,

    pending: struct {
        render_list: wl.list.Head(Window, .pending_render_list_link),
    },

    inflight: struct {
        render_list: wl.list.Head(Window, .inflight_render_list_link),
    },
},

windows: wl.list.Head(Window, .link),

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

/// Number of inflight configures sent in the current transaction.
inflight_configures: u32 = 0,
transaction_timeout: *wl.EventSource,
/// Set to true if applyPending() is called while a transaction is inflight.
/// If true when a transaction completes, causes applyPending() to be called again.
pending_state_dirty: bool = false,

pub fn init(root: *Root) !void {
    const output_layout = try wlr.OutputLayout.create(server.wl_server);
    errdefer output_layout.destroy();

    const scene = try wlr.Scene.create();
    errdefer scene.tree.node.destroy();

    const interactive_content = try scene.tree.createSceneTree();
    const drag_icons = try scene.tree.createSceneTree();
    const hidden_tree = try scene.tree.createSceneTree();
    hidden_tree.node.setEnabled(false);

    const outputs = try interactive_content.createSceneTree();
    const override_redirect = if (build_options.xwayland) try interactive_content.createSceneTree();

    const event_loop = server.wl_server.getEventLoop();
    const transaction_timeout = try event_loop.addTimer(*Root, handleTransactionTimeout, root);
    errdefer transaction_timeout.remove();

    root.* = .{
        .scene = scene,
        .interactive_content = interactive_content,
        .drag_icons = drag_icons,
        .layers = .{
            .outputs = outputs,
            .override_redirect = override_redirect,
        },
        .wm = .{
            .pending = .{
                .render_list = undefined,
            },
            .inflight = .{
                .render_list = undefined,
            },
        },
        .hidden = .{
            .tree = hidden_tree,
            .pending = .{
                .render_list = undefined,
            },
            .inflight = .{
                .render_list = undefined,
            },
        },
        .windows = undefined,
        .output_layout = output_layout,
        .all_outputs = undefined,
        .active_outputs = undefined,

        .presentation = try wlr.Presentation.create(server.wl_server, server.backend),
        .xdg_output_manager = try wlr.XdgOutputManagerV1.create(server.wl_server, output_layout),
        .output_manager = try wlr.OutputManagerV1.create(server.wl_server),
        .power_manager = try wlr.OutputPowerManagerV1.create(server.wl_server),
        .gamma_control_manager = try wlr.GammaControlManagerV1.create(server.wl_server),
        .transaction_timeout = transaction_timeout,
    };
    root.wm.pending.render_list.init();
    root.wm.inflight.render_list.init();
    root.hidden.pending.render_list.init();
    root.hidden.inflight.render_list.init();

    root.windows.init();
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
    root.transaction_timeout.remove();
}

pub const AtResult = struct {
    node: *wlr.SceneNode,
    surface: ?*wlr.Surface,
    sx: f64,
    sy: f64,
    data: SceneNodeData.Data,
};

/// Return information about what is currently rendered in the interactive_content
/// tree at the given layout coordinates, taking surface input regions into account.
pub fn at(root: Root, lx: f64, ly: f64) ?AtResult {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    const node = root.interactive_content.node.at(lx, ly, &sx, &sy) orelse return null;

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
    output.tree.node.setEnabled(false);

    output.active_link.remove();
    output.active_link.init();

    // Close all layer surfaces on the removed output
    for ([_]zwlr.LayerShellV1.Layer{ .overlay, .top, .bottom, .background }) |layer| {
        const tree = output.layerSurfaceTree(layer);
        var it = tree.children.safeIterator(.forward);
        while (it.next()) |scene_node| {
            assert(scene_node.type == .tree);
            if (@as(?*SceneNodeData, @ptrFromInt(scene_node.data))) |node_data| {
                node_data.data.layer_surface.wlr_layer_surface.destroy();
            }
        }
    }

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

/// Trigger asynchronous application of pending state for all outputs and windows.
/// Changes will not be applied to the scene graph until the layout generator
/// generates a new layout for all outputs and all affected clients ack a
/// configure and commit a new buffer.
pub fn applyPending(root: *Root) void {
    {
        // Changes to the pending state may require a focus update to keep
        // state consistent. Instead of having focus(null) calls spread all
        // around the codebase and risk forgetting one, always ensure focus
        // state is synchronized here.
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) node.data.focus(null);
    }

    // If there is already a transaction inflight, wait until it completes.
    if (root.inflight_configures > 0) {
        root.pending_state_dirty = true;
        return;
    }
    root.pending_state_dirty = false;

    {
        var it = root.hidden.pending.render_list.iterator(.forward);
        while (it.next()) |window| {
            window.inflight_render_list_link.remove();
            root.hidden.inflight.render_list.append(window);
        }
    }

    {
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) {
            const cursor = &node.data.cursor;

            switch (cursor.mode) {
                .passthrough, .down => {},
                inline .move, .resize => |data| {
                    if (data.window.inflight.fullscreen) {
                        cursor.mode = .passthrough;
                        data.window.pending.resizing = false;
                        data.window.inflight.resizing = false;
                    }
                },
            }

            cursor.inflight_mode = cursor.mode;
        }
    }

    root.sendConfigures();
}

fn sendConfigures(root: *Root) void {
    assert(root.inflight_configures == 0);

    {
        var it = root.wm.inflight.render_list.iterator(.forward);
        while (it.next()) |window| {
            assert(!window.inflight_transaction);
            window.inflight_transaction = true;

            // This can happen if a window is unmapped while a layout demand including it is inflight
            // If a window has been unmapped, don't send it a configure.
            if (!window.mapped) continue;

            if (window.configure()) {
                root.inflight_configures += 1;

                window.saveSurfaceTree();
                window.sendFrameDone();
            }
        }
    }

    if (root.inflight_configures > 0) {
        std.log.scoped(.transaction).debug("started transaction with {} pending configure(s)", .{
            root.inflight_configures,
        });

        root.transaction_timeout.timerUpdate(100) catch {
            std.log.scoped(.transaction).err("failed to update timer", .{});
            root.commitTransaction();
        };
    } else {
        root.commitTransaction();
    }
}

fn handleTransactionTimeout(root: *Root) c_int {
    std.log.scoped(.transaction).err("timeout occurred, some imperfect frames may be shown", .{});

    root.inflight_configures = 0;
    root.commitTransaction();

    return 0;
}

pub fn notifyConfigured(root: *Root) void {
    root.inflight_configures -= 1;
    if (root.inflight_configures == 0) {
        // Disarm the timer, as we didn't timeout
        root.transaction_timeout.timerUpdate(0) catch std.log.scoped(.transaction).err("error disarming timer", .{});
        root.commitTransaction();
    }
}

/// Apply the inflight state and drop stashed buffers. This means that
/// the next frame drawn will be the post-transaction state of the
/// layout. Should only be called after all clients have configured for
/// the new layout. If called early imperfect frames may be drawn.
fn commitTransaction(root: *Root) void {
    assert(root.inflight_configures == 0);

    std.log.scoped(.transaction).debug("commiting transaction", .{});

    {
        var it = root.hidden.inflight.render_list.safeIterator(.forward);
        while (it.next()) |window| {
            window.tree.node.reparent(root.hidden.tree);
            window.popup_tree.node.reparent(root.hidden.tree);
        }
    }

    {
        var it = root.wm.inflight.render_list.iterator(.forward);
        while (it.next()) |window| {
            window.commitTransaction();

            window.tree.node.setEnabled(true);
            window.popup_tree.node.setEnabled(true);
        }
    }

    {
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) node.data.cursor.updateState();
    }

    {
        // This must be done after updating cursor state in case the window was the target of move/resize.
        var it = root.hidden.inflight.render_list.safeIterator(.forward);
        while (it.next()) |window| {
            window.dropSavedSurfaceTree();
            if (window.destroying) window.destroy(.assert);
        }
    }

    server.idle_inhibit_manager.checkActive();

    if (root.pending_state_dirty) {
        root.applyPending();
    }
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

        output.tree.node.setEnabled(!box.empty());
        output.tree.node.setPosition(box.x, box.y);
        output.scene_output.setPosition(box.x, box.y);

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

    if (action == .apply) root.applyPending();

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
