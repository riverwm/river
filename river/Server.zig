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
const mem = std.mem;
const fmt = std.fmt;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const c = @import("c.zig");
const util = @import("util.zig");

const Config = @import("Config.zig");
const Control = @import("Control.zig");
const IdleInhibitorManager = @import("IdleInhibitorManager.zig");
const InputManager = @import("InputManager.zig");
const LayerSurface = @import("LayerSurface.zig");
const LayoutManager = @import("LayoutManager.zig");
const LockManager = @import("LockManager.zig");
const Output = @import("Output.zig");
const Root = @import("Root.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const StatusManager = @import("StatusManager.zig");
const XdgDecoration = @import("XdgDecoration.zig");
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");
const XwaylandView = @import("XwaylandView.zig");

const log = std.log.scoped(.server);

wl_server: *wl.Server,

sigint_source: *wl.EventSource,
sigterm_source: *wl.EventSource,

backend: *wlr.Backend,

renderer: *wlr.Renderer,
allocator: *wlr.Allocator,

xdg_shell: *wlr.XdgShell,
new_xdg_surface: wl.Listener(*wlr.XdgSurface),

xdg_decoration_manager: *wlr.XdgDecorationManagerV1,
new_toplevel_decoration: wl.Listener(*wlr.XdgToplevelDecorationV1),

layer_shell: *wlr.LayerShellV1,
new_layer_surface: wl.Listener(*wlr.LayerSurfaceV1),

xwayland: if (build_options.xwayland) *wlr.Xwayland else void,
new_xwayland_surface: if (build_options.xwayland) wl.Listener(*wlr.XwaylandSurface) else void,

foreign_toplevel_manager: *wlr.ForeignToplevelManagerV1,

xdg_activation: *wlr.XdgActivationV1,
request_activate: wl.Listener(*wlr.XdgActivationV1.event.RequestActivate),
activated_unmapped_surfaces: std.ArrayListUnmanaged(struct { surface: *wlr.Surface, pending_tags: u32 }),

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

    self.renderer = try wlr.Renderer.autocreate(self.backend);
    errdefer self.renderer.destroy();
    try self.renderer.initServer(self.wl_server);

    self.allocator = try wlr.Allocator.autocreate(self.backend, self.renderer);
    errdefer self.allocator.destroy();

    const compositor = try wlr.Compositor.create(self.wl_server, self.renderer);
    _ = try wlr.Subcompositor.create(self.wl_server);

    self.xdg_shell = try wlr.XdgShell.create(self.wl_server, 5);
    self.new_xdg_surface.setNotify(handleNewXdgSurface);
    self.xdg_shell.events.new_surface.add(&self.new_xdg_surface);

    self.xdg_decoration_manager = try wlr.XdgDecorationManagerV1.create(self.wl_server);
    self.new_toplevel_decoration.setNotify(handleNewToplevelDecoration);
    self.xdg_decoration_manager.events.new_toplevel_decoration.add(&self.new_toplevel_decoration);

    self.layer_shell = try wlr.LayerShellV1.create(self.wl_server);
    self.new_layer_surface.setNotify(handleNewLayerSurface);
    self.layer_shell.events.new_surface.add(&self.new_layer_surface);

    if (build_options.xwayland) {
        self.xwayland = try wlr.Xwayland.create(self.wl_server, compositor, false);
        self.new_xwayland_surface.setNotify(handleNewXwaylandSurface);
        self.xwayland.events.new_surface.add(&self.new_xwayland_surface);
    }

    self.foreign_toplevel_manager = try wlr.ForeignToplevelManagerV1.create(self.wl_server);

    self.xdg_activation = try wlr.XdgActivationV1.create(self.wl_server);
    self.xdg_activation.events.request_activate.add(&self.request_activate);
    self.request_activate.setNotify(handleRequestActivate);
    self.activated_unmapped_surfaces = .{};

    _ = try wlr.PrimarySelectionDeviceManagerV1.create(self.wl_server);

    self.config = try Config.init();
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

    self.new_xdg_surface.link.remove();
    self.new_layer_surface.link.remove();
    self.request_activate.link.remove();

    if (build_options.xwayland) {
        self.new_xwayland_surface.link.remove();
        self.xwayland.destroy();
    }

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

fn handleNewXdgSurface(_: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
    if (xdg_surface.role == .popup) {
        log.debug("new xdg_popup", .{});
        return;
    }

    log.debug("new xdg_toplevel", .{});

    XdgToplevel.create(xdg_surface.role_data.toplevel) catch {
        log.err("out of memory", .{});
        xdg_surface.resource.postNoMemory();
        return;
    };
}

fn handleNewToplevelDecoration(
    _: *wl.Listener(*wlr.XdgToplevelDecorationV1),
    wlr_decoration: *wlr.XdgToplevelDecorationV1,
) void {
    const xdg_toplevel = @intToPtr(*XdgToplevel, wlr_decoration.surface.data);

    // TODO(wlroots): The next wlroots version will handle this for us
    if (xdg_toplevel.decoration != null) {
        wlr_decoration.resource.postError(
            .already_constructed,
            "xdg_toplevel already has a decoration object",
        );
        return;
    }

    XdgDecoration.init(wlr_decoration);
}

fn handleNewLayerSurface(listener: *wl.Listener(*wlr.LayerSurfaceV1), wlr_layer_surface: *wlr.LayerSurfaceV1) void {
    const self = @fieldParentPtr(Self, "new_layer_surface", listener);

    log.debug(
        "new layer surface: namespace {s}, layer {s}, anchor {b:0>4}, size {},{}, margin {},{},{},{}, exclusive_zone {}",
        .{
            wlr_layer_surface.namespace,
            @tagName(wlr_layer_surface.current.layer),
            @bitCast(u32, wlr_layer_surface.current.anchor),
            wlr_layer_surface.current.desired_width,
            wlr_layer_surface.current.desired_height,
            wlr_layer_surface.current.margin.top,
            wlr_layer_surface.current.margin.right,
            wlr_layer_surface.current.margin.bottom,
            wlr_layer_surface.current.margin.left,
            wlr_layer_surface.current.exclusive_zone,
        },
    );

    // If the new layer surface does not have an output assigned to it, use the
    // first output or close the surface if none are available.
    if (wlr_layer_surface.output == null) {
        const output = self.input_manager.defaultSeat().focused_output orelse {
            log.err("no output available for layer surface '{s}'", .{wlr_layer_surface.namespace});
            wlr_layer_surface.destroy();
            return;
        };

        log.debug("new layer surface had null output, assigning it to output '{s}'", .{output.wlr_output.name});
        wlr_layer_surface.output = output.wlr_output;
    }

    LayerSurface.create(wlr_layer_surface) catch {
        wlr_layer_surface.resource.postNoMemory();
        return;
    };
}

fn handleNewXwaylandSurface(_: *wl.Listener(*wlr.XwaylandSurface), xwayland_surface: *wlr.XwaylandSurface) void {
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
        _ = XwaylandView.create(xwayland_surface) catch {
            log.err("out of memory", .{});
            return;
        };
    }
}

fn handleRequestActivate(
    listener: *wl.Listener(*wlr.XdgActivationV1.event.RequestActivate),
    event: *wlr.XdgActivationV1.event.RequestActivate,
) void {
    const server = @fieldParentPtr(Self, "request_activate", listener);

    const name = mem.span(event.token.name());
    const tags: ?u32 = blk: {
        if (!mem.startsWith(u8, name, "!river")) break :blk null;
        var it = mem.split(u8, name, "-");
        _ = it.next() orelse break :blk null;
        const tag_str = it.next() orelse break :blk null;
        if (it.next() == null) break :blk null;
        const tags = fmt.parseInt(u32, tag_str, 10) catch break :blk null;
        break :blk tags;
    };

    if (SceneNodeData.fromSurface(event.surface)) |node_data| {
        switch (node_data.data) {
            .view => |view| {
                if (view.current.focus == 0) view.pending.urgent = true;
                if (tags) |t| view.pending.tags = t;
                server.root.applyPending();
            },
            else => |tag| {
                log.info("ignoring xdg-activation-v1 activate request of {s} surface", .{@tagName(tag)});
            },
        }
        return;
    }

    // The surface is not a mapped view.
    if (tags) |t| {
        const unmapped_surface = server.activated_unmapped_surfaces.addOne(util.gpa) catch return;
        unmapped_surface.surface = event.surface;
        unmapped_surface.pending_tags = t;
    }
}
