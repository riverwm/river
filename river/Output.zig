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

const std = @import("std");
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;

const c = @import("c.zig");
const log = @import("log.zig");
const render = @import("render.zig");
const util = @import("util.zig");

const Box = @import("Box.zig");
const LayerSurface = @import("LayerSurface.zig");
const Root = @import("Root.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const AttachMode = @import("view_stack.zig").AttachMode;
const OutputStatus = @import("OutputStatus.zig");

const State = struct {
    /// A bit field of focused tags
    tags: u32,
};

root: *Root,
wlr_output: *wlr.Output,

/// All layer surfaces on the output, indexed by the layer enum.
layers: [4]std.TailQueue(LayerSurface) = [1]std.TailQueue(LayerSurface){.{}} ** 4,

/// The area left for views and other layer surfaces after applying the
/// exclusive zones of exclusive layer surfaces.
/// TODO: this should be part of the output's State
usable_box: Box,

/// The top of the stack is the "most important" view.
views: ViewStack(View) = .{},

/// The double-buffered state of the output.
current: State = State{ .tags = 1 << 0 },
pending: State = State{ .tags = 1 << 0 },

/// Number of views in "master" section of the screen.
master_count: u32 = 1,

/// Percentage of the total screen that the master section takes up.
master_factor: f64 = 0.6,

/// Current layout of the output. If it is "full", river will use the full
/// layout. Otherwise river assumes it contains a string which, when executed
/// with sh, will result in a layout.
layout: []const u8,

/// Determines where new views will be attached to the view stack.
attach_mode: AttachMode = .top,

/// List of status tracking objects relaying changes to this output to clients.
status_trackers: std.SinglyLinkedList(OutputStatus) = .{},

destroy: wl.Listener(*wlr.Output) = undefined,
enable: wl.Listener(*wlr.Output) = undefined,
frame: wl.Listener(*wlr.Output) = undefined,
mode: wl.Listener(*wlr.Output) = undefined,

pub fn init(self: *Self, root: *Root, wlr_output: *wlr.Output) !void {
    // Some backends don't have modes. DRM+KMS does, and we need to set a mode
    // before we can use the output. The mode is a tuple of (width, height,
    // refresh rate), and each monitor supports only a specific set of modes. We
    // just pick the monitor's preferred mode, a more sophisticated compositor
    // would let the user configure it.
    if (wlr_output.preferredMode()) |mode| {
        wlr_output.setMode(mode);
        wlr_output.enable(true);
        try wlr_output.commit();
    }

    const layout = try std.mem.dupe(util.gpa, u8, "full");
    errdefer util.gpa.free(layout);

    self.* = .{
        .root = root,
        .wlr_output = wlr_output,
        .layout = layout,
        .usable_box = undefined,
    };
    wlr_output.data = @ptrToInt(self);

    self.destroy.setNotify(handleDestroy);
    wlr_output.events.destroy.add(&self.destroy);

    self.enable.setNotify(handleEnable);
    wlr_output.events.enable.add(&self.enable);

    self.frame.setNotify(handleFrame);
    wlr_output.events.frame.add(&self.frame);

    self.mode.setNotify(handleMode);
    wlr_output.events.mode.add(&self.mode);

    if (wlr_output.isNoop()) {
        // A noop output is always 0 x 0
        self.usable_box = .{
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
        };
    } else {
        // Ensure that a cursor image at the output's scale factor is loaded
        // for each seat.
        var it = root.server.input_manager.seats.first;
        while (it) |node| : (it = node.next) {
            const seat = &node.data;
            seat.cursor.xcursor_manager.load(wlr_output.scale) catch
                log.err(.cursor, "failed to load xcursor theme at scale {}", .{wlr_output.scale});
        }

        const effective_resolution = self.getEffectiveResolution();
        self.usable_box = .{
            .x = 0,
            .y = 0,
            .width = effective_resolution.width,
            .height = effective_resolution.height,
        };
    }
}

pub fn getLayer(self: *Self, layer: zwlr.LayerShellV1.Layer) *std.TailQueue(LayerSurface) {
    return &self.layers[@intCast(usize, @enumToInt(layer))];
}

pub fn sendViewTags(self: Self) void {
    var it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendViewTags();
}

/// The single build in layout, which makes all views use the maximum available
/// space.
fn layoutFull(self: *Self, visible_count: u32) void {
    const border_width = self.root.server.config.border_width;
    const view_padding = self.root.server.config.view_padding;
    const outer_padding = self.root.server.config.outer_padding;
    const xy_offset = outer_padding + border_width + view_padding;

    var full_box: Box = .{
        .x = self.usable_box.x + @intCast(i32, xy_offset),
        .y = self.usable_box.y + @intCast(i32, xy_offset),
        .width = self.usable_box.width - (2 * xy_offset),
        .height = self.usable_box.height - (2 * xy_offset),
    };

    var it = ViewStack(View).iter(self.views.first, .forward, self.pending.tags, arrangeFilter);
    while (it.next()) |view| {
        view.pending.box = full_box;
        view.applyConstraints();
    }
}

const LayoutError = error{
    BadExitCode,
    WrongViewCount,
};

/// Parse 4 integers separated by spaces into a Box
fn parseBox(buffer: []const u8) !Box {
    var it = std.mem.split(buffer, " ");

    const box = Box{
        .x = try std.fmt.parseInt(i32, it.next() orelse return error.NotEnoughArguments, 10),
        .y = try std.fmt.parseInt(i32, it.next() orelse return error.NotEnoughArguments, 10),
        .width = try std.fmt.parseInt(u32, it.next() orelse return error.NotEnoughArguments, 10),
        .height = try std.fmt.parseInt(u32, it.next() orelse return error.NotEnoughArguments, 10),
    };

    if (it.next() != null) return error.TooManyArguments;

    return box;
}

test "parse window configuration" {
    const testing = @import("std").testing;
    const box = try parseBox("5 10 100 200");
    testing.expect(box.x == 5);
    testing.expect(box.y == 10);
    testing.expect(box.width == 100);
    testing.expect(box.height == 200);
}

/// Execute an external layout function, parse its output and apply the layout
/// to the output.
fn layoutExternal(self: *Self, visible_count: u32) !void {
    const config = self.root.server.config;
    const xy_offset = @intCast(i32, config.border_width + config.outer_padding + config.view_padding);
    const delta_size = (config.border_width + config.view_padding) * 2;
    const layout_width = @intCast(u32, self.usable_box.width) - config.outer_padding * 2;
    const layout_height = @intCast(u32, self.usable_box.height) - config.outer_padding * 2;

    var arena = std.heap.ArenaAllocator.init(util.gpa);
    defer arena.deinit();

    // Assemble command
    const layout_command = try std.fmt.allocPrint0(&arena.allocator, "{} {} {} {d} {} {}", .{
        self.layout,
        visible_count,
        self.master_count,
        self.master_factor,
        layout_width,
        layout_height,
    });
    const cmd = [_:null]?[*:0]const u8{ "/bin/sh", "-c", layout_command, null };
    const stdout_pipe = try std.os.pipe();

    const pid = try std.os.fork();
    if (pid == 0) {
        std.os.dup2(stdout_pipe[1], std.os.STDOUT_FILENO) catch c._exit(1);
        std.os.close(stdout_pipe[0]);
        std.os.close(stdout_pipe[1]);
        std.os.execveZ("/bin/sh", &cmd, std.c.environ) catch c._exit(1);
    }
    std.os.close(stdout_pipe[1]);
    const stdout = std.fs.File{ .handle = stdout_pipe[0] };
    defer stdout.close();

    // TODO abort after a timeout
    const ret = std.os.waitpid(pid, 0);
    if (!std.os.WIFEXITED(ret.status) or std.os.WEXITSTATUS(ret.status) != 0)
        return LayoutError.BadExitCode;

    const buffer = try stdout.inStream().readAllAlloc(&arena.allocator, 1024);

    // Parse layout command output
    var view_boxen = std.ArrayList(Box).init(&arena.allocator);
    var parse_it = std.mem.split(buffer, "\n");
    while (parse_it.next()) |token| {
        if (std.mem.eql(u8, token, "")) break;
        var box = try parseBox(token);
        box.x += self.usable_box.x + xy_offset;
        box.y += self.usable_box.y + xy_offset;

        if (box.width > delta_size) box.width -= delta_size;
        if (box.height > delta_size) box.height -= delta_size;

        try view_boxen.append(box);
    }

    if (view_boxen.items.len != visible_count) return LayoutError.WrongViewCount;

    // Apply window configuration to views
    var i: u32 = 0;
    var view_it = ViewStack(View).iter(self.views.first, .forward, self.pending.tags, arrangeFilter);
    while (view_it.next()) |view| : (i += 1) {
        view.pending.box = view_boxen.items[i];
        view.applyConstraints();
    }
}

fn arrangeFilter(view: *View, filter_tags: u32) bool {
    return !view.destroying and !view.pending.float and
        !view.pending.fullscreen and view.pending.tags & filter_tags != 0;
}

/// Arrange all views on the output for the current layout. Modifies only
/// pending state, the changes are not appplied until a transaction is started
/// and completed.
pub fn arrangeViews(self: *Self) void {
    if (self == &self.root.noop_output) return;

    // Count up views that will be arranged by the layout
    var layout_count: u32 = 0;
    var it = ViewStack(View).iter(self.views.first, .forward, self.pending.tags, arrangeFilter);
    while (it.next() != null) layout_count += 1;

    // If the usable area has a zero dimension, trying to arrange the layout
    // would cause an underflow and is pointless anyway.
    if (layout_count == 0 or self.usable_box.width == 0 or self.usable_box.height == 0) return;

    if (std.mem.eql(u8, self.layout, "full")) return layoutFull(self, layout_count);

    self.layoutExternal(layout_count) catch |err| {
        switch (err) {
            LayoutError.BadExitCode => log.err(.layout, "layout command exited with non-zero return code", .{}),
            LayoutError.WrongViewCount => log.err(.layout, "mismatch between window configuration and visible window counts", .{}),
            else => log.err(.layout, "failed to use external layout: {}", .{err}),
        }
        log.err(.layout, "falling back to internal layout", .{});
        self.layoutFull(layout_count);
    };
}

/// Arrange all layer surfaces of this output and adjust the usable area
pub fn arrangeLayers(self: *Self) void {
    const effective_resolution = self.getEffectiveResolution();
    const full_box: Box = .{
        .x = 0,
        .y = 0,
        .width = effective_resolution.width,
        .height = effective_resolution.height,
    };

    // This box is modified as exclusive zones are applied
    var usable_box = full_box;

    const layers = [_]zwlr.LayerShellV1.Layer{ .overlay, .top, .bottom, .background };

    // Arrange all layer surfaces with exclusive zones, applying them to the
    // usable box along the way.
    for (layers) |layer| self.arrangeLayer(self.getLayer(layer).*, full_box, &usable_box, true);

    // If the the usable_box has changed, we need to rearrange the output
    if (!std.meta.eql(self.usable_box, usable_box)) {
        self.usable_box = usable_box;
        self.arrangeViews();
    }

    // Arrange the layers without exclusive zones
    for (layers) |layer| self.arrangeLayer(self.getLayer(layer).*, full_box, &usable_box, false);

    // Find the topmost layer surface in the top or overlay layers which
    // requests keyboard interactivity if any.
    const topmost_surface = outer: for (layers[0..2]) |layer| {
        // Iterate in reverse order since the last layer is rendered on top
        var it = self.getLayer(layer).last;
        while (it) |node| : (it = node.prev) {
            const layer_surface = &node.data;
            if (layer_surface.wlr_layer_surface.current.keyboard_interactive) {
                break :outer layer_surface;
            }
        }
    } else null;

    var it = self.root.server.input_manager.seats.first;
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
            if (!seat.focused.layer.wlr_layer_surface.current.keyboard_interactive) {
                seat.setFocusRaw(.{ .none = {} });
                seat.focus(null);
            }
        }
    }
}

/// Arrange the layer surfaces of a given layer
fn arrangeLayer(
    self: *Self,
    layer: std.TailQueue(LayerSurface),
    full_box: Box,
    usable_box: *Box,
    exclusive: bool,
) void {
    var it = layer.first;
    while (it) |node| : (it = node.next) {
        const layer_surface = &node.data;
        const current_state = layer_surface.wlr_layer_surface.current;

        // If the value of exclusive_zone is greater than zero, then it exclusivly
        // occupies some area of the screen.
        if (exclusive != (current_state.exclusive_zone > 0)) continue;

        // If the exclusive zone is set to -1, this means the the client would like
        // to ignore any exclusive zones and use the full area of the output.
        const bounds = if (current_state.exclusive_zone == -1) &full_box else usable_box;

        var new_box: Box = undefined;

        // Horizontal alignment
        if (current_state.desired_width == 0) {
            std.debug.assert(current_state.anchor.right and current_state.anchor.left);
            new_box.x = bounds.x + @intCast(i32, current_state.margin.left);
            new_box.width = bounds.width - (current_state.margin.left + current_state.margin.right);
        } else if (current_state.anchor.left) {
            new_box.x = bounds.x + @intCast(i32, current_state.margin.left);
            new_box.width = current_state.desired_width;
        } else if (current_state.anchor.right) {
            new_box.x = bounds.x + @intCast(i32, bounds.width - current_state.desired_width -
                current_state.margin.right);
            new_box.width = current_state.desired_width;
        } else {
            new_box.x = bounds.x + @intCast(i32, bounds.width / 2 - current_state.desired_width / 2);
            new_box.width = current_state.desired_width;
        }

        // Vertical alignment
        if (current_state.desired_height == 0) {
            std.debug.assert(current_state.anchor.top and current_state.anchor.bottom);
            new_box.y = bounds.y + @intCast(i32, current_state.margin.top);
            new_box.height = bounds.height - (current_state.margin.top + current_state.margin.bottom);
        } else if (current_state.anchor.top) {
            new_box.y = bounds.y + @intCast(i32, current_state.margin.top);
            new_box.height = current_state.desired_height;
        } else if (current_state.anchor.bottom) {
            new_box.y = bounds.y + @intCast(i32, bounds.height - current_state.desired_height -
                current_state.margin.bottom);
            new_box.height = current_state.desired_height;
        } else {
            new_box.y = bounds.y + @intCast(i32, bounds.height / 2 - current_state.desired_height / 2);
            new_box.height = current_state.desired_height;
        }

        layer_surface.box = new_box;

        // Apply the exclusive zone to the current bounds
        const edges = [4]struct {
            single: zwlr.LayerSurfaceV1.Anchor,
            triple: zwlr.LayerSurfaceV1.Anchor,
            to_increase: ?*i32,
            to_decrease: *u32,
            margin: u32,
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
                current_state.exclusive_zone + @intCast(i32, edge.margin) > 0)
            {
                const delta = current_state.exclusive_zone + @intCast(i32, edge.margin);
                if (edge.to_increase) |value| value.* += delta;
                edge.to_decrease.* -= @intCast(u32, delta);
                break;
            }
        }

        // Tell the client to assume the new size
        log.debug(.layer_shell, "send configure, {} x {}", .{ layer_surface.box.width, layer_surface.box.height });
        layer_surface.wlr_layer_surface.configure(layer_surface.box.width, layer_surface.box.height);
    }
}

/// Called when the output is destroyed. Evacuate all views from the output
/// and then remove it from the list of outputs.
fn handleDestroy(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const self = @fieldParentPtr(Self, "destroy", listener);
    const root = self.root;

    log.debug(.server, "output '{}' destroyed", .{self.wlr_output.name});

    // Remove the destroyed output from root if it wasn't already removed
    root.removeOutput(self);

    var it = root.all_outputs.first;
    while (it) |all_node| : (it = all_node.next) {
        if (all_node.data == self) {
            root.all_outputs.remove(all_node);
            break;
        }
    }

    // Remove all listeners
    self.destroy.link.remove();
    self.enable.link.remove();
    self.frame.link.remove();
    self.mode.link.remove();

    // Free all memory and clean up the wlr.Output
    self.wlr_output.data = undefined;
    util.gpa.free(self.layout);

    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    util.gpa.destroy(node);
}

fn handleEnable(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const self = @fieldParentPtr(Self, "enable", listener);

    // Add the output to root.outputs and the output layout if it has not
    // already been added.
    if (wlr_output.enabled) self.root.addOutput(self);
}

fn handleFrame(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    // This function is called every time an output is ready to display a frame,
    // generally at the output's refresh rate (e.g. 60Hz).
    const self = @fieldParentPtr(Self, "frame", listener);
    render.renderOutput(self);
}

fn handleMode(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const self = @fieldParentPtr(Self, "mode", listener);
    self.arrangeLayers();
    self.arrangeViews();
    self.root.startTransaction();
}

pub fn getEffectiveResolution(self: *Self) struct { width: u32, height: u32 } {
    var width: c_int = undefined;
    var height: c_int = undefined;
    self.wlr_output.effectiveResolution(&width, &height);
    return .{
        .width = @intCast(u32, width),
        .height = @intCast(u32, height),
    };
}
