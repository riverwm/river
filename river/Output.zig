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

const Self = @This();

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const fmt = std.fmt;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;

const render = @import("render.zig");
const server = &@import("main.zig").server;
const util = @import("util.zig");

const LayerSurface = @import("LayerSurface.zig");
const Layout = @import("Layout.zig");
const LayoutDemand = @import("LayoutDemand.zig");
const LockSurface = @import("LockSurface.zig");
const OutputStatus = @import("OutputStatus.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const View = @import("View.zig");

wlr_output: *wlr.Output,

/// The area left for views and other layer surfaces after applying the
/// exclusive zones of exclusive layer surfaces.
/// TODO: this should be part of the output's State
usable_box: wlr.Box,

/// Scene node representing the entire output.
/// Position must be updated when the output is moved in the layout.
tree: *wlr.SceneTree,
normal_content: *wlr.SceneTree,
locked_content: *wlr.SceneTree,

/// Child nodes of normal_content
layers: struct {
    background_color_rect: *wlr.SceneRect,
    /// Background layer shell layer
    background: *wlr.SceneTree,
    /// Bottom layer shell layer
    bottom: *wlr.SceneTree,
    /// Tiled and floating views
    views: *wlr.SceneTree,
    /// Top layer shell layer
    top: *wlr.SceneTree,
    /// Fullscreen views
    fullscreen: *wlr.SceneTree,
    /// Overlay layer shell layer
    overlay: *wlr.SceneTree,
    /// xdg-popups of views and layer-shell surfaces
    popups: *wlr.SceneTree,
},

/// Tracks the currently presented frame on the output as it pertains to ext-session-lock.
/// The output is initially considered blanked:
/// If using the DRM backend it will be blanked with the initial modeset.
/// If using the Wayland or X11 backend nothing will be visible until the first frame is rendered.
lock_render_state: enum {
    /// Normal, "unlocked" content may be visible.
    unlocked,
    /// Submitted a blank buffer but the buffer has not yet been presented.
    /// Normal, "unlocked" content may be visible.
    pending_blank,
    /// A blank buffer has been presented.
    blanked,
    /// Submitted the lock surface buffer but the buffer has not yet been presented.
    /// Normal, "unlocked" content may be visible.
    pending_lock_surface,
    /// The lock surface buffer has been presented.
    lock_surface,
} = .blanked,

/// The state of the output that is directly acted upon/modified through user input.
///
/// Pending state will be copied to the pending state and communicated to clients
/// to be applied as a single atomic transaction across all clients as soon as any
/// in progress transaction has been completed.
///
/// On completion of a transaction
/// Any time pending state is modified Root.dirty must be set.
///
pending: struct {
    /// A bit field of focused tags
    tags: u32 = 1 << 0,
    /// The stack of views in focus/rendering order.
    ///
    /// This contains views that aren't currently visible because they do not
    /// match the tags of the output.
    ///
    /// This list is used to update the rendering order of nodes in the scene
    /// graph when the pending state is committed.
    focus_stack: wl.list.Head(View, .pending_focus_stack_link),
    /// The stack of views acted upon by window management commands such
    /// as focus-view, zoom, etc.
    ///
    /// This contains views that aren't currently visible because they do not
    /// match the tags of the output. This means that a filtered version of the
    /// list must be used for window management commands.
    ///
    /// This includes both floating/fullscreen views and those arranged in the layout.
    wm_stack: wl.list.Head(View, .pending_wm_stack_link),
},

/// The state most recently sent to the layout generator and clients.
/// This state is immutable until all clients have replied and the transaction
/// is completed, at which point this inflight state is copied to current.
inflight: struct {
    /// A bit field of focused tags
    tags: u32 = 1 << 0,
    /// See pending.focus_stack
    focus_stack: wl.list.Head(View, .inflight_focus_stack_link),
    /// See pending.wm_stack
    wm_stack: wl.list.Head(View, .inflight_wm_stack_link),
    /// The view to be made fullscreen, if any.
    fullscreen: ?*View = null,
    layout_demand: ?LayoutDemand = null,
},

/// The current state represented by the scene graph.
/// There is no need to have a current focus_stack/wm_stack copy as this
/// information is transferred from the inflight state to the scene graph
/// as an inflight transaction completes.
current: struct {
    /// A bit field of focused tags
    tags: u32 = 1 << 0,
    /// The currently fullscreen view, if any.
    fullscreen: ?*View = null,
} = .{},

/// Remembered version of tags (from last run)
previous_tags: u32 = 1 << 0,

/// List of all layouts
layouts: std.TailQueue(Layout) = .{},

/// The current layout namespace of the output. If null,
/// config.default_layout_namespace should be used instead.
/// Call handleLayoutNamespaceChange() after setting this.
layout_namespace: ?[]const u8 = null,

/// The last set layout name.
layout_name: ?[:0]const u8 = null,

/// Active layout, or null if views are un-arranged.
///
/// If null, views which are manually moved or resized (with the pointer or
/// or command) will not be automatically set to floating. Everything is
/// already floating, so this would be an unexpected change of a views state
/// the user will only notice once a layout affects the views. So instead we
/// "snap back" all manually moved views the next time a layout is active.
/// This is similar to dwms behvaviour. Note that this of course does not
/// affect already floating views.
layout: ?*Layout = null,

status: OutputStatus,

destroy: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleDestroy),
enable: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleEnable),
mode: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleMode),
frame: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleFrame),
present: wl.Listener(*wlr.Output.event.Present) = wl.Listener(*wlr.Output.event.Present).init(handlePresent),

pub fn create(wlr_output: *wlr.Output) !void {
    const node = try util.gpa.create(std.TailQueue(Self).Node);
    errdefer util.gpa.destroy(node);
    const output = &node.data;

    if (!wlr_output.initRender(server.allocator, server.renderer)) return error.InitRenderFailed;

    if (wlr_output.preferredMode()) |preferred_mode| {
        wlr_output.setMode(preferred_mode);
        wlr_output.enable(true);
        wlr_output.commit() catch {
            var it = wlr_output.modes.iterator(.forward);
            while (it.next()) |mode| {
                if (mode == preferred_mode) continue;
                wlr_output.setMode(mode);
                wlr_output.commit() catch continue;
                // This mode works, use it
                break;
            }
            // If no mode works, then we will just leave the output disabled.
            // Perhaps the user will want to set a custom mode using wlr-output-management.
        };
    }

    var width: c_int = undefined;
    var height: c_int = undefined;
    wlr_output.effectiveResolution(&width, &height);

    const tree = try server.root.layers.outputs.createSceneTree();
    const normal_content = try tree.createSceneTree();

    output.* = .{
        .wlr_output = wlr_output,
        .tree = tree,
        .normal_content = normal_content,
        .locked_content = try tree.createSceneTree(),
        .layers = .{
            .background_color_rect = try normal_content.createSceneRect(
                width,
                height,
                &server.config.background_color,
            ),
            .background = try normal_content.createSceneTree(),
            .bottom = try normal_content.createSceneTree(),
            .views = try normal_content.createSceneTree(),
            .top = try normal_content.createSceneTree(),
            .fullscreen = try normal_content.createSceneTree(),
            .overlay = try normal_content.createSceneTree(),
            .popups = try normal_content.createSceneTree(),
        },
        .pending = .{
            .focus_stack = undefined,
            .wm_stack = undefined,
        },
        .inflight = .{
            .focus_stack = undefined,
            .wm_stack = undefined,
        },
        .usable_box = .{
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
        },
        .status = undefined,
    };
    wlr_output.data = @ptrToInt(output);

    output.pending.focus_stack.init();
    output.pending.wm_stack.init();
    output.inflight.focus_stack.init();
    output.inflight.wm_stack.init();

    output.status.init();

    _ = try output.layers.fullscreen.createSceneRect(width, height, &[_]f32{ 0, 0, 0, 1.0 });
    output.layers.fullscreen.node.setEnabled(false);

    wlr_output.events.destroy.add(&output.destroy);
    wlr_output.events.enable.add(&output.enable);
    wlr_output.events.mode.add(&output.mode);
    wlr_output.events.frame.add(&output.frame);
    wlr_output.events.present.add(&output.present);

    // Ensure that a cursor image at the output's scale factor is loaded
    // for each seat.
    var it = server.input_manager.seats.first;
    while (it) |seat_node| : (it = seat_node.next) {
        const seat = &seat_node.data;
        seat.cursor.xcursor_manager.load(wlr_output.scale) catch
            std.log.scoped(.cursor).err("failed to load xcursor theme at scale {}", .{wlr_output.scale});
    }

    output.setTitle();

    const ptr_node = try util.gpa.create(std.TailQueue(*Self).Node);
    ptr_node.data = &node.data;
    server.root.all_outputs.append(ptr_node);

    handleEnable(&output.enable, wlr_output);
}

pub fn layerSurfaceTree(self: Self, layer: zwlr.LayerShellV1.Layer) *wlr.SceneTree {
    const trees = [_]*wlr.SceneTree{
        self.layers.background,
        self.layers.bottom,
        self.layers.top,
        self.layers.overlay,
    };
    return trees[@intCast(usize, @enumToInt(layer))];
}

/// Arrange all layer surfaces of this output and adjust the usable area.
/// Will arrange views as well if the usable area changes.
pub fn arrangeLayers(self: *Self) void {
    var full_box: wlr.Box = .{
        .x = 0,
        .y = 0,
        .width = undefined,
        .height = undefined,
    };
    self.wlr_output.effectiveResolution(&full_box.width, &full_box.height);

    // This box is modified as exclusive zones are applied
    var usable_box = full_box;

    for ([_]zwlr.LayerShellV1.Layer{ .overlay, .top, .bottom, .background }) |layer| {
        const tree = self.layerSurfaceTree(layer);
        var it = tree.children.iterator(.forward);
        while (it.next()) |node| {
            assert(node.type == .tree);
            if (@intToPtr(?*SceneNodeData, node.data)) |node_data| {
                const layer_surface = node_data.data.layer_surface;
                layer_surface.scene_layer_surface.configure(&full_box, &usable_box);
                layer_surface.popup_tree.node.setPosition(
                    layer_surface.scene_layer_surface.tree.node.x,
                    layer_surface.scene_layer_surface.tree.node.y,
                );
            }
        }
    }

    self.usable_box = usable_box;
}

fn handleDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const output = @fieldParentPtr(Self, "destroy", listener);

    std.log.scoped(.server).debug("output '{s}' destroyed", .{output.wlr_output.name});

    // Remove the destroyed output from root if it wasn't already removed
    server.root.removeOutput(output);

    assert(output.pending.focus_stack.empty());
    assert(output.pending.wm_stack.empty());
    assert(output.inflight.focus_stack.empty());
    assert(output.inflight.wm_stack.empty());
    assert(output.inflight.layout_demand == null);
    assert(output.layouts.len == 0);

    var it = server.root.all_outputs.first;
    while (it) |all_node| : (it = all_node.next) {
        if (all_node.data == output) {
            server.root.all_outputs.remove(all_node);
            break;
        }
    }

    output.destroy.link.remove();
    output.enable.link.remove();
    output.frame.link.remove();
    output.mode.link.remove();
    output.present.link.remove();

    if (output.layout_namespace) |namespace| util.gpa.free(namespace);

    output.wlr_output.data = 0;

    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", output);
    util.gpa.destroy(node);
}

fn handleEnable(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const self = @fieldParentPtr(Self, "enable", listener);

    // Add the output to root.outputs and the output layout if it has not
    // already been added.
    if (wlr_output.enabled) server.root.addOutput(self);

    // We can't assert the current state of normal_content/locked_content
    // here as this output may be newly created.
    if (wlr_output.enabled) {
        switch (server.lock_manager.state) {
            .unlocked => {
                self.lock_render_state = .unlocked;
                self.normal_content.node.setEnabled(true);
                self.locked_content.node.setEnabled(false);
            },
            .waiting_for_lock_surfaces, .waiting_for_blank, .locked => {
                assert(self.lock_render_state == .blanked);
                self.normal_content.node.setEnabled(false);
                self.locked_content.node.setEnabled(true);
            },
        }
    } else {
        // Disabling and re-enabling an output always blanks it.
        self.lock_render_state = .blanked;
    }
}

fn handleFrame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const self = @fieldParentPtr(Self, "frame", listener);
    render.renderOutput(self);
}

fn handleMode(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const self = @fieldParentPtr(Self, "mode", listener);

    {
        var width: c_int = undefined;
        var height: c_int = undefined;
        self.wlr_output.effectiveResolution(&width, &height);
        self.layers.background_color_rect.setSize(width, height);

        var it = self.layers.fullscreen.children.iterator(.forward);
        const background_color_rect = @fieldParentPtr(wlr.SceneRect, "node", it.next().?);
        background_color_rect.setSize(width, height);
    }

    server.root.applyPending();
}

fn handlePresent(
    listener: *wl.Listener(*wlr.Output.event.Present),
    event: *wlr.Output.event.Present,
) void {
    const self = @fieldParentPtr(Self, "present", listener);

    switch (self.lock_render_state) {
        .unlocked => assert(server.lock_manager.state != .locked),
        .pending_blank, .pending_lock_surface => {
            if (!event.presented) {
                self.lock_render_state = .unlocked;
                return;
            }

            self.lock_render_state = switch (self.lock_render_state) {
                .pending_blank => .blanked,
                .pending_lock_surface => .lock_surface,
                .unlocked, .blanked, .lock_surface => unreachable,
            };

            if (server.lock_manager.state != .locked) {
                server.lock_manager.maybeLock();
            }
        },
        .blanked, .lock_surface => {},
    }
}

fn setTitle(self: Self) void {
    const title = fmt.allocPrintZ(util.gpa, "river - {s}", .{self.wlr_output.name}) catch return;
    defer util.gpa.free(title);
    if (self.wlr_output.isWl()) {
        self.wlr_output.wlSetTitle(title);
    } else if (wlr.config.has_x11_backend and self.wlr_output.isX11()) {
        self.wlr_output.x11SetTitle(title);
    }
}

pub fn handleLayoutNamespaceChange(self: *Self) void {
    // The user changed the layout namespace of this output. Try to find a
    // matching layout.
    var it = self.layouts.first;
    self.layout = while (it) |node| : (it = node.next) {
        if (mem.eql(u8, self.layoutNamespace(), node.data.namespace)) break &node.data;
    } else null;
    server.root.applyPending();
}

pub fn layoutNamespace(self: Self) []const u8 {
    return self.layout_namespace orelse server.config.default_layout_namespace;
}
