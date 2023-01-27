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

const build_options = @import("build_options");
const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const c = @import("c.zig");
const util = @import("util.zig");

const Config = @import("Config.zig");
const Control = @import("Control.zig");
const DecorationManager = @import("DecorationManager.zig");
const InputManager = @import("InputManager.zig");
const LayerSurface = @import("LayerSurface.zig");
const LayoutManager = @import("LayoutManager.zig");
const LockManager = @import("LockManager.zig");
const Output = @import("Output.zig");
const Root = @import("Root.zig");
const StatusManager = @import("StatusManager.zig");
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");
const XwaylandView = @import("XwaylandView.zig");
const IdleInhibitorManager = @import("IdleInhibitorManager.zig");

const log = std.log.scoped(.server);

wl_server: *wl.Server,

sigint_source: *wl.EventSource,
sigterm_source: *wl.EventSource,

backend: *wlr.Backend,
headless_backend: *wlr.Backend,

renderer: *wlr.Renderer,
allocator: *wlr.Allocator,

xdg_shell: *wlr.XdgShell,
new_xdg_surface: wl.Listener(*wlr.XdgSurface),

layer_shell: *wlr.LayerShellV1,
new_layer_surface: wl.Listener(*wlr.LayerSurfaceV1),

xwayland: if (build_options.xwayland) *wlr.Xwayland else void,
new_xwayland_surface: if (build_options.xwayland) wl.Listener(*wlr.XwaylandSurface) else void,

xdg_activation: *wlr.XdgActivationV1,

decoration_manager: DecorationManager,
input_manager: InputManager,
root: Root,
config: Config,
control: Control,
status_manager: StatusManager,
layout_manager: LayoutManager,
idle_inhibitor_manager: IdleInhibitorManager,
lock_manager: LockManager,

pub fn init(self: *Self) !void {
    self.wl_server = try wl.Server.create();
    errdefer self.wl_server.destroy();

    const loop = self.wl_server.getEventLoop();
    self.sigint_source = try loop.addSignal(*wl.Server, std.os.SIG.INT, terminate, self.wl_server);
    errdefer self.sigint_source.remove();
    self.sigterm_source = try loop.addSignal(*wl.Server, std.os.SIG.TERM, terminate, self.wl_server);
    errdefer self.sigterm_source.remove();

    // This frees itself when the wl.Server is destroyed
    self.backend = try wlr.Backend.autocreate(self.wl_server);

    // This backend is used to create a headless output for use when no actual
    // outputs are available. This frees itself when the wl.Server is destroyed.
    self.headless_backend = try wlr.Backend.createHeadless(self.wl_server);

    self.renderer = try wlr.Renderer.autocreate(self.backend);
    errdefer self.renderer.destroy();
    try self.renderer.initServer(self.wl_server);

    self.allocator = try wlr.Allocator.autocreate(self.backend, self.renderer);
    errdefer self.allocator.destroy();

    const compositor = try wlr.Compositor.create(self.wl_server, self.renderer);
    _ = try wlr.Subcompositor.create(self.wl_server);

    self.xdg_shell = try wlr.XdgShell.create(self.wl_server, 2);
    self.new_xdg_surface.setNotify(handleNewXdgSurface);
    self.xdg_shell.events.new_surface.add(&self.new_xdg_surface);

    self.layer_shell = try wlr.LayerShellV1.create(self.wl_server);
    self.new_layer_surface.setNotify(handleNewLayerSurface);
    self.layer_shell.events.new_surface.add(&self.new_layer_surface);

    if (build_options.xwayland) {
        self.xwayland = try wlr.Xwayland.create(self.wl_server, compositor, false);
        self.new_xwayland_surface.setNotify(handleNewXwaylandSurface);
        self.xwayland.events.new_surface.add(&self.new_xwayland_surface);
    }

    self.xdg_activation = try wlr.XdgActivationV1.create(self.wl_server);

    _ = try wlr.PrimarySelectionDeviceManagerV1.create(self.wl_server);

    self.config = try Config.init();
    try self.decoration_manager.init();
    try self.root.init();
    // Must be called after root is initialized
    try self.input_manager.init();
    try self.control.init();
    try self.status_manager.init();
    try self.layout_manager.init();
    try self.idle_inhibitor_manager.init();
    try self.lock_manager.init();

    // These all free themselves when the wl_server is destroyed
    _ = try wlr.DataDeviceManager.create(self.wl_server);
    _ = try wlr.DataControlManagerV1.create(self.wl_server);
    _ = try wlr.ExportDmabufManagerV1.create(self.wl_server);
    _ = try wlr.GammaControlManagerV1.create(self.wl_server);
    _ = try wlr.ScreencopyManagerV1.create(self.wl_server);
    _ = try wlr.SinglePixelBufferManagerV1.create(self.wl_server);
    _ = try wlr.Viewporter.create(self.wl_server);
}

/// Free allocated memory and clean up. Note: order is important here
pub fn deinit(self: *Self) void {
    self.sigint_source.remove();
    self.sigterm_source.remove();

    if (build_options.xwayland) self.xwayland.destroy();

    self.wl_server.destroyClients();

    self.backend.destroy();
    self.renderer.destroy();
    self.allocator.destroy();

    self.root.deinit();
    self.input_manager.deinit();
    self.idle_inhibitor_manager.deinit();
    self.lock_manager.deinit();

    self.wl_server.destroy();

    self.config.deinit();
}

/// Create the socket, start the backend, and setup the environment
pub fn start(self: Self) !void {
    var buf: [11]u8 = undefined;
    const socket = try self.wl_server.addSocketAuto(&buf);
    try self.backend.start();
    // TODO: don't use libc's setenv
    if (c.setenv("WAYLAND_DISPLAY", socket.ptr, 1) < 0) return error.SetenvError;
    if (build_options.xwayland) {
        if (c.setenv("DISPLAY", self.xwayland.display_name, 1) < 0) return error.SetenvError;
    }
}

/// Handle SIGINT and SIGTERM by gracefully stopping the server
fn terminate(_: c_int, wl_server: *wl.Server) c_int {
    wl_server.terminate();
    return 0;
}

fn handleNewXdgSurface(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
    const self = @fieldParentPtr(Self, "new_xdg_surface", listener);

    if (xdg_surface.role == .popup) {
        log.debug("new xdg_popup", .{});
        return;
    }

    log.debug("new xdg_toplevel", .{});

    const output = self.input_manager.defaultSeat().focused_output;
    XdgToplevel.create(output, xdg_surface.role_data.toplevel) catch {
        log.err("out of memory", .{});
        xdg_surface.resource.postNoMemory();
        return;
    };
}

/// This event is raised when the layer_shell recieves a new surface from a client.
fn handleNewLayerSurface(listener: *wl.Listener(*wlr.LayerSurfaceV1), wlr_layer_surface: *wlr.LayerSurfaceV1) void {
    const self = @fieldParentPtr(Self, "new_layer_surface", listener);

    log.debug(
        "new layer surface: namespace {s}, layer {s}, anchor {b:0>4}, size {},{}, margin {},{},{},{}, exclusive_zone {}",
        .{
            wlr_layer_surface.namespace,
            @tagName(wlr_layer_surface.pending.layer),
            @bitCast(u32, wlr_layer_surface.pending.anchor),
            wlr_layer_surface.pending.desired_width,
            wlr_layer_surface.pending.desired_height,
            wlr_layer_surface.pending.margin.top,
            wlr_layer_surface.pending.margin.right,
            wlr_layer_surface.pending.margin.bottom,
            wlr_layer_surface.pending.margin.left,
            wlr_layer_surface.pending.exclusive_zone,
        },
    );

    // If the new layer surface does not have an output assigned to it, use the
    // first output or close the surface if none are available.
    if (wlr_layer_surface.output == null) {
        const output = self.input_manager.defaultSeat().focused_output;
        if (output == &self.root.noop_output) {
            log.err("no output available for layer surface '{s}'", .{wlr_layer_surface.namespace});
            wlr_layer_surface.destroy();
            return;
        }

        log.debug("new layer surface had null output, assigning it to output '{s}'", .{output.wlr_output.name});
        wlr_layer_surface.output = output.wlr_output;
    }

    // The layer surface will add itself to the proper list of the output on map
    const output = @intToPtr(*Output, wlr_layer_surface.output.?.data);
    const node = util.gpa.create(std.TailQueue(LayerSurface).Node) catch {
        wlr_layer_surface.resource.postNoMemory();
        return;
    };
    node.data.init(output, wlr_layer_surface);
}

fn handleNewXwaylandSurface(listener: *wl.Listener(*wlr.XwaylandSurface), xwayland_surface: *wlr.XwaylandSurface) void {
    const self = @fieldParentPtr(Self, "new_xwayland_surface", listener);

    log.debug(
        "new xwayland surface: title='{?s}', class='{?s}', override redirect={}",
        .{ xwayland_surface.title, xwayland_surface.class, xwayland_surface.override_redirect },
    );

    if (xwayland_surface.override_redirect) {
        _ = XwaylandOverrideRedirect.create(xwayland_surface) catch {
            log.err("out of memory", .{});
            return;
        };
    } else {
        const output = self.input_manager.defaultSeat().focused_output;
        _ = XwaylandView.create(output, xwayland_surface) catch {
            log.err("out of memory", .{});
            return;
        };
    }
}
