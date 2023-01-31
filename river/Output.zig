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
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const OutputStatus = @import("OutputStatus.zig");

const State = struct {
    /// A bit field of focused tags
    tags: u32,

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
};

wlr_output: *wlr.Output,

/// All layer surfaces on the output, indexed by the layer enum.
layers: [4]std.TailQueue(LayerSurface) = [1]std.TailQueue(LayerSurface){.{}} ** 4,

/// The area left for views and other layer surfaces after applying the
/// exclusive zones of exclusive layer surfaces.
/// TODO: this should be part of the output's State
usable_box: wlr.Box,

/// Scene node representing the entire output.
/// Position must be updated when the output is moved in the layout.
tree: *wlr.SceneTree,
normal_content: *wlr.SceneTree,
locked_content: *wlr.SceneTree,

/// The top of the stack is the "most important" view.
views: ViewStack(View) = .{},

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

/// The double-buffered state of the output.
current: State = State{ .tags = 1 << 0 },
pending: State = State{ .tags = 1 << 0 },

/// Remembered version of tags (from last run)
previous_tags: u32 = 1 << 0,

/// The currently active LayoutDemand
layout_demand: ?LayoutDemand = null,

/// List of all layouts
layouts: std.TailQueue(Layout) = .{},

/// The current layout namespace of the output. If null,
/// config.default_layout_namespace should be used instead.
/// Call handleLayoutNamespaceChange() after setting this.
layout_namespace: ?[]const u8 = null,

/// The last set layout name.
layout_name: ?[:0]const u8 = null,

/// List of status tracking objects relaying changes to this output to clients.
status_trackers: std.SinglyLinkedList(OutputStatus) = .{},

destroy: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleDestroy),
enable: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleEnable),
mode: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleMode),
frame: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleFrame),
present: wl.Listener(*wlr.Output.event.Present) = wl.Listener(*wlr.Output.event.Present).init(handlePresent),

pub fn create(wlr_output: *wlr.Output) !void {
    const node = try util.gpa.create(std.TailQueue(Self).Node);
    errdefer util.gpa.destroy(node);
    const self = &node.data;

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

    const tree = try server.root.scene.tree.createSceneTree();
    self.* = .{
        .wlr_output = wlr_output,
        .tree = tree,
        .normal_content = try tree.createSceneTree(),
        .locked_content = try tree.createSceneTree(),
        .usable_box = undefined,
    };
    wlr_output.data = @ptrToInt(self);

    wlr_output.events.destroy.add(&self.destroy);
    wlr_output.events.enable.add(&self.enable);
    wlr_output.events.mode.add(&self.mode);
    wlr_output.events.frame.add(&self.frame);
    wlr_output.events.present.add(&self.present);

    // Ensure that a cursor image at the output's scale factor is loaded
    // for each seat.
    var it = server.input_manager.seats.first;
    while (it) |seat_node| : (it = seat_node.next) {
        const seat = &seat_node.data;
        seat.cursor.xcursor_manager.load(wlr_output.scale) catch
            std.log.scoped(.cursor).err("failed to load xcursor theme at scale {}", .{wlr_output.scale});
    }

    self.usable_box = .{
        .x = 0,
        .y = 0,
        .width = undefined,
        .height = undefined,
    };
    self.wlr_output.effectiveResolution(&self.usable_box.width, &self.usable_box.height);

    self.setTitle();

    const ptr_node = try util.gpa.create(std.TailQueue(*Self).Node);
    ptr_node.data = &node.data;
    server.root.all_outputs.append(ptr_node);

    handleEnable(&self.enable, self.wlr_output);
}

pub fn getLayer(self: *Self, layer: zwlr.LayerShellV1.Layer) *std.TailQueue(LayerSurface) {
    return &self.layers[@intCast(usize, @enumToInt(layer))];
}

pub fn sendViewTags(self: Self) void {
    var it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendViewTags();
}

pub fn sendUrgentTags(self: Self) void {
    var urgent_tags: u32 = 0;

    var view_it = self.views.first;
    while (view_it) |node| : (view_it = node.next) {
        if (node.view.current.urgent) urgent_tags |= node.view.current.tags;
    }

    var it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendUrgentTags(urgent_tags);
}

pub fn sendLayoutName(self: Self) void {
    std.debug.assert(self.layout_name != null);
    var it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendLayoutName(self.layout_name.?);
}

pub fn sendLayoutNameClear(self: Self) void {
    std.debug.assert(self.layout_name == null);
    var it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendLayoutNameClear();
}

pub fn arrangeFilter(view: *View, filter_tags: u32) bool {
    return view.tree.node.enabled and !view.pending.float and !view.pending.fullscreen and
        view.pending.tags & filter_tags != 0;
}

/// Start a layout demand with the currently active (pending) layout.
/// Note that this function does /not/ decide which layout shall be active. That
/// is done in two places: 1) When the user changed the layout namespace option
/// of this output and 2) when a new layout is added.
///
/// If no layout is active, all views will simply retain their current
/// dimensions. So without any active layouts, river will function like a simple
/// floating WM.
///
/// The changes of view dimensions are async. Therefore all transactions are
/// blocked until the layout demand has either finished or was aborted. Both
/// cases will start a transaction.
pub fn arrangeViews(self: *Self) void {
    if (self == &server.root.noop_output) return;

    // If there is already an active layout demand, discard it.
    if (self.layout_demand) |demand| {
        demand.deinit();
        self.layout_demand = null;
    }

    // We only need to do something if there is an active layout.
    if (self.pending.layout) |layout| {
        // If the usable area has a zero dimension, trying to arrange the layout
        // would cause an underflow and is pointless anyway.
        if (self.usable_box.width == 0 or self.usable_box.height == 0) return;

        // How many views will be part of the layout?
        var views: u32 = 0;
        var view_it = ViewStack(View).iter(self.views.first, .forward, self.pending.tags, arrangeFilter);
        while (view_it.next() != null) views += 1;

        // No need to arrange an empty output.
        if (views == 0) return;

        // Note that this is async. A layout demand will start a transaction
        // once its done.
        layout.startLayoutDemand(views);
    }
}

const ArrangeLayersTarget = enum { mapped, unmapped };

/// Arrange all layer surfaces of this output and adjust the usable area.
/// Will arrange views as well if the usable area changes.
/// If target is unmapped, this function is pure aside from the
/// wlr.LayerSurfaceV1.configure() calls made on umapped layer surfaces.
pub fn arrangeLayers(self: *Self, target: ArrangeLayersTarget) void {
    var full_box: wlr.Box = .{
        .x = 0,
        .y = 0,
        .width = undefined,
        .height = undefined,
    };
    self.wlr_output.effectiveResolution(&full_box.width, &full_box.height);

    // This box is modified as exclusive zones are applied
    var usable_box = full_box;

    const layers = [_]zwlr.LayerShellV1.Layer{ .overlay, .top, .bottom, .background };

    // Arrange all layer surfaces with exclusive zones, applying them to the
    // usable box along the way.
    for (layers) |layer| arrangeLayer(self.getLayer(layer).*, full_box, &usable_box, true, target);

    // If the the usable_box has changed, we need to rearrange the output
    if (target == .mapped and !std.meta.eql(self.usable_box, usable_box)) {
        self.usable_box = usable_box;
        self.arrangeViews();
    }

    // Arrange the layers without exclusive zones
    for (layers) |layer| arrangeLayer(self.getLayer(layer).*, full_box, &usable_box, false, target);

    if (target == .unmapped) return;

    if (server.lock_manager.state != .unlocked) return;

    // Find the topmost layer surface in the top or overlay layers which
    // requests keyboard interactivity if any.
    const topmost_surface = outer: for (layers[0..2]) |layer| {
        // Iterate in reverse order since the last layer is rendered on top
        var it = self.getLayer(layer).last;
        while (it) |node| : (it = node.prev) {
            const layer_surface = &node.data;
            if (layer_surface.wlr_layer_surface.current.keyboard_interactive == .exclusive) {
                break :outer layer_surface;
            }
        }
    } else null;

    var it = server.input_manager.seats.first;
    while (it) |node| : (it = node.next) {
        const seat = &node.data;

        // Only grab focus of seats which have the output focused
        if (seat.focused_output != self) continue;

        if (topmost_surface) |to_focus| {
            // If we found a surface that requires focus, grab the focus of all
            // seats.
            seat.setFocusRaw(.{ .layer = to_focus });
        } else if (seat.focused == .layer) {
            // If the seat is currently focusing a layer without keyboard
            // interactivity, stop focusing that layer.
            if (seat.focused.layer.wlr_layer_surface.current.keyboard_interactive != .exclusive) {
                seat.setFocusRaw(.{ .none = {} });
                seat.focus(null);
            }
        }
    }
}

/// Arrange the layer surfaces of a given layer
fn arrangeLayer(
    layer: std.TailQueue(LayerSurface),
    full_box: wlr.Box,
    usable_box: *wlr.Box,
    exclusive: bool,
    target: ArrangeLayersTarget,
) void {
    var it = layer.first;
    while (it) |node| : (it = node.next) {
        const layer_surface = &node.data;
        const current_state = layer_surface.wlr_layer_surface.current;

        const desired_width = @intCast(u31, math.min(math.maxInt(u31), current_state.desired_width));
        const desired_height = @intCast(u31, math.min(math.maxInt(u31), current_state.desired_height));

        // If the value of exclusive_zone is greater than zero, then it exclusivly
        // occupies some area of the screen.
        if (exclusive != (current_state.exclusive_zone > 0)) continue;

        // If the exclusive zone is set to -1, this means the the client would like
        // to ignore any exclusive zones and use the full area of the output.
        const bounds = if (current_state.exclusive_zone == -1) &full_box else usable_box;

        var new_box: wlr.Box = undefined;

        // Horizontal alignment
        if (desired_width == 0) {
            assert(current_state.anchor.right and current_state.anchor.left);
            new_box.x = bounds.x + current_state.margin.left;
            new_box.width = bounds.width - (current_state.margin.left + current_state.margin.right);
        } else if (current_state.anchor.left == current_state.anchor.right) {
            new_box.x = bounds.x + @divTrunc(bounds.width, 2) - desired_width / 2;
            new_box.width = desired_width;
        } else if (current_state.anchor.left) {
            new_box.x = bounds.x + current_state.margin.left;
            new_box.width = desired_width;
        } else {
            assert(current_state.anchor.right);
            new_box.x = bounds.x + bounds.width - desired_width - current_state.margin.right;
            new_box.width = desired_width;
        }

        // Vertical alignment
        if (desired_height == 0) {
            assert(current_state.anchor.top and current_state.anchor.bottom);
            new_box.y = bounds.y + current_state.margin.top;
            new_box.height = bounds.height - (current_state.margin.top + current_state.margin.bottom);
        } else if (current_state.anchor.top == current_state.anchor.bottom) {
            new_box.y = bounds.y + @divTrunc(bounds.height, 2) - desired_height / 2;
            new_box.height = desired_height;
        } else if (current_state.anchor.top) {
            new_box.y = bounds.y + current_state.margin.top;
            new_box.height = desired_height;
        } else {
            assert(current_state.anchor.bottom);
            new_box.y = bounds.y + bounds.height - desired_height - current_state.margin.bottom;
            new_box.height = desired_height;
        }

        // Apply the exclusive zone to the current bounds
        const edges = [4]struct {
            single: zwlr.LayerSurfaceV1.Anchor,
            triple: zwlr.LayerSurfaceV1.Anchor,
            to_increase: ?*i32,
            to_decrease: *i32,
            margin: i32,
        }{
            .{
                .single = .{ .top = true },
                .triple = .{ .top = true, .left = true, .right = true },
                .to_increase = &usable_box.y,
                .to_decrease = &usable_box.height,
                .margin = current_state.margin.top,
            },
            .{
                .single = .{ .bottom = true },
                .triple = .{ .bottom = true, .left = true, .right = true },
                .to_increase = null,
                .to_decrease = &usable_box.height,
                .margin = current_state.margin.bottom,
            },
            .{
                .single = .{ .left = true },
                .triple = .{ .left = true, .top = true, .bottom = true },
                .to_increase = &usable_box.x,
                .to_decrease = &usable_box.width,
                .margin = current_state.margin.left,
            },
            .{
                .single = .{ .right = true },
                .triple = .{ .right = true, .top = true, .bottom = true },
                .to_increase = null,
                .to_decrease = &usable_box.width,
                .margin = current_state.margin.right,
            },
        };

        for (edges) |edge| {
            if ((std.meta.eql(current_state.anchor, edge.single) or std.meta.eql(current_state.anchor, edge.triple)) and
                current_state.exclusive_zone + edge.margin > 0)
            {
                const delta = current_state.exclusive_zone + edge.margin;
                if (edge.to_increase) |value| value.* += delta;
                edge.to_decrease.* -= delta;
                break;
            }
        }

        switch (target) {
            .mapped => {
                assert(layer_surface.wlr_layer_surface.mapped);
                layer_surface.box = new_box;
                _ = layer_surface.wlr_layer_surface.configure(
                    @intCast(u32, new_box.width),
                    @intCast(u32, new_box.height),
                );
            },
            .unmapped => if (!layer_surface.wlr_layer_surface.mapped) {
                _ = layer_surface.wlr_layer_surface.configure(
                    @intCast(u32, new_box.width),
                    @intCast(u32, new_box.height),
                );
            },
        }
    }
}

fn handleDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const self = @fieldParentPtr(Self, "destroy", listener);

    std.log.scoped(.server).debug("output '{s}' destroyed", .{self.wlr_output.name});

    // Remove the destroyed output from root if it wasn't already removed
    server.root.removeOutput(self);
    assert(self.views.first == null and self.views.last == null);
    for (self.layers) |layer| assert(layer.len == 0);
    assert(self.layouts.len == 0);

    var it = server.root.all_outputs.first;
    while (it) |all_node| : (it = all_node.next) {
        if (all_node.data == self) {
            server.root.all_outputs.remove(all_node);
            break;
        }
    }

    // Remove all listeners
    self.destroy.link.remove();
    self.enable.link.remove();
    self.frame.link.remove();
    self.mode.link.remove();
    self.present.link.remove();

    // Free all memory and clean up the wlr.Output
    if (self.layout_demand) |demand| demand.deinit();
    if (self.layout_namespace) |namespace| util.gpa.free(namespace);

    self.wlr_output.data = undefined;

    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
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
    self.arrangeLayers(.mapped);
    self.arrangeViews();
    server.root.startTransaction();
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
    self.pending.layout = while (it) |node| : (it = node.next) {
        if (mem.eql(u8, self.layoutNamespace(), node.data.namespace)) break &node.data;
    } else null;
    self.arrangeViews();
    server.root.startTransaction();
}

pub fn layoutNamespace(self: Self) []const u8 {
    return self.layout_namespace orelse server.config.default_layout_namespace;
}
