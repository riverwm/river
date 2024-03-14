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

const Server = @This();

const build_options = @import("build_options");
const std = @import("std");
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
const Seat = @import("Seat.zig");
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
session: ?*wlr.Session,

renderer: *wlr.Renderer,
allocator: *wlr.Allocator,

compositor: *wlr.Compositor,

xdg_shell: *wlr.XdgShell,
new_xdg_surface: wl.Listener(*wlr.XdgSurface) =
    wl.Listener(*wlr.XdgSurface).init(handleNewXdgSurface),

xdg_decoration_manager: *wlr.XdgDecorationManagerV1,
new_toplevel_decoration: wl.Listener(*wlr.XdgToplevelDecorationV1) =
    wl.Listener(*wlr.XdgToplevelDecorationV1).init(handleNewToplevelDecoration),

layer_shell: *wlr.LayerShellV1,
new_layer_surface: wl.Listener(*wlr.LayerSurfaceV1) =
    wl.Listener(*wlr.LayerSurfaceV1).init(handleNewLayerSurface),

xwayland: if (build_options.xwayland) ?*wlr.Xwayland else void = if (build_options.xwayland) null,
new_xwayland_surface: if (build_options.xwayland) wl.Listener(*wlr.XwaylandSurface) else void =
    if (build_options.xwayland) wl.Listener(*wlr.XwaylandSurface).init(handleNewXwaylandSurface),

foreign_toplevel_manager: *wlr.ForeignToplevelManagerV1,

xdg_activation: *wlr.XdgActivationV1,
request_activate: wl.Listener(*wlr.XdgActivationV1.event.RequestActivate) =
    wl.Listener(*wlr.XdgActivationV1.event.RequestActivate).init(handleRequestActivate),

cursor_shape_manager: *wlr.CursorShapeManagerV1,
request_set_cursor_shape: wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape) =
    wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape).init(handleRequestSetCursorShape),

input_manager: InputManager,
root: Root,
config: Config,
control: Control,
status_manager: StatusManager,
layout_manager: LayoutManager,
idle_inhibitor_manager: IdleInhibitorManager,
lock_manager: LockManager,

pub fn init(server: *Server, runtime_xwayland: bool) !void {
    // We intentionally don't try to prevent memory leaks on error in this function
    // since river will exit during initialization anyway if there is an error.
    // This keeps the code simpler and more readable.

    const wl_server = try wl.Server.create();

    var session: ?*wlr.Session = undefined;
    const backend = try wlr.Backend.autocreate(wl_server, &session);
    const renderer = try wlr.Renderer.autocreate(backend);

    const compositor = try wlr.Compositor.create(wl_server, 6, renderer);

    const loop = wl_server.getEventLoop();
    server.* = .{
        .wl_server = wl_server,
        .sigint_source = try loop.addSignal(*wl.Server, std.os.SIG.INT, terminate, wl_server),
        .sigterm_source = try loop.addSignal(*wl.Server, std.os.SIG.TERM, terminate, wl_server),

        .backend = backend,
        .session = session,
        .renderer = renderer,
        .allocator = try wlr.Allocator.autocreate(backend, renderer),

        .compositor = compositor,
        .xdg_shell = try wlr.XdgShell.create(wl_server, 5),
        .xdg_decoration_manager = try wlr.XdgDecorationManagerV1.create(wl_server),
        .layer_shell = try wlr.LayerShellV1.create(wl_server, 4),
        .foreign_toplevel_manager = try wlr.ForeignToplevelManagerV1.create(wl_server),
        .xdg_activation = try wlr.XdgActivationV1.create(wl_server),
        .cursor_shape_manager = try wlr.CursorShapeManagerV1.create(server.wl_server, 1),

        .config = try Config.init(),

        .root = undefined,
        .input_manager = undefined,
        .control = undefined,
        .status_manager = undefined,
        .layout_manager = undefined,
        .idle_inhibitor_manager = undefined,
        .lock_manager = undefined,
    };

    try renderer.initWlShm(wl_server);
    if (renderer.getDmabufFormats() != null and renderer.getDrmFd() >= 0) {
        // wl_drm is a legacy interface and all clients should switch to linux_dmabuf.
        // However, enough widely used clients still rely on wl_drm that the pragmatic option
        // is to keep it around for the near future.
        // TODO remove wl_drm support
        _ = try wlr.Drm.create(wl_server, renderer);

        _ = try wlr.LinuxDmabufV1.createWithRenderer(wl_server, 4, renderer);
    }

    _ = try wlr.Subcompositor.create(wl_server);
    _ = try wlr.PrimarySelectionDeviceManagerV1.create(wl_server);
    _ = try wlr.DataDeviceManager.create(wl_server);
    _ = try wlr.DataControlManagerV1.create(wl_server);
    _ = try wlr.ExportDmabufManagerV1.create(wl_server);
    _ = try wlr.ScreencopyManagerV1.create(wl_server);
    _ = try wlr.SinglePixelBufferManagerV1.create(wl_server);
    _ = try wlr.Viewporter.create(wl_server);
    _ = try wlr.FractionalScaleManagerV1.create(wl_server, 1);

    if (build_options.xwayland and runtime_xwayland) {
        server.xwayland = try wlr.Xwayland.create(wl_server, compositor, false);
        server.xwayland.?.events.new_surface.add(&server.new_xwayland_surface);
    }

    try server.root.init();
    try server.input_manager.init();
    try server.control.init();
    try server.status_manager.init();
    try server.layout_manager.init();
    try server.idle_inhibitor_manager.init();
    try server.lock_manager.init();

    server.xdg_shell.events.new_surface.add(&server.new_xdg_surface);
    server.xdg_decoration_manager.events.new_toplevel_decoration.add(&server.new_toplevel_decoration);
    server.layer_shell.events.new_surface.add(&server.new_layer_surface);
    server.xdg_activation.events.request_activate.add(&server.request_activate);
    server.cursor_shape_manager.events.request_set_shape.add(&server.request_set_cursor_shape);

    wl_server.setGlobalFilter(*Server, globalFilter, server);
}

/// Free allocated memory and clean up. Note: order is important here
pub fn deinit(server: *Server) void {
    server.sigint_source.remove();
    server.sigterm_source.remove();

    server.new_xdg_surface.link.remove();
    server.new_layer_surface.link.remove();
    server.request_activate.link.remove();

    if (build_options.xwayland) {
        if (server.xwayland) |xwayland| {
            server.new_xwayland_surface.link.remove();
            xwayland.destroy();
        }
    }

    server.wl_server.destroyClients();

    server.backend.destroy();

    // The scene graph needs to be destroyed after the backend but before the renderer
    // Output destruction requires the scene graph to still be around while the scene
    // graph may require the renderer to still be around to destroy textures it seems.
    server.root.scene.tree.node.destroy();

    server.renderer.destroy();
    server.allocator.destroy();

    server.root.deinit();
    server.input_manager.deinit();
    server.idle_inhibitor_manager.deinit();
    server.lock_manager.deinit();

    server.wl_server.destroy();

    server.config.deinit();
}

/// Create the socket, start the backend, and setup the environment
pub fn start(server: Server) !void {
    var buf: [11]u8 = undefined;
    const socket = try server.wl_server.addSocketAuto(&buf);
    try server.backend.start();
    // TODO: don't use libc's setenv
    if (c.setenv("WAYLAND_DISPLAY", socket.ptr, 1) < 0) return error.SetenvError;
    if (build_options.xwayland) {
        if (server.xwayland) |xwayland| {
            if (c.setenv("DISPLAY", xwayland.display_name, 1) < 0) return error.SetenvError;
        }
    }
}

fn globalFilter(client: *const wl.Client, global: *const wl.Global, server: *Server) bool {
    // Only expose the xwalyand_shell_v1 global to the Xwayland process.
    if (build_options.xwayland) {
        if (server.xwayland) |xwayland| {
            if (global == xwayland.shell_v1.global) {
                if (xwayland.server) |xwayland_server| {
                    return client == xwayland_server.client;
                }
                return false;
            }
        }
    }

    return true;
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

    XdgToplevel.create(xdg_surface.role_data.toplevel.?) catch {
        log.err("out of memory", .{});
        xdg_surface.resource.postNoMemory();
        return;
    };
}

fn handleNewToplevelDecoration(
    _: *wl.Listener(*wlr.XdgToplevelDecorationV1),
    wlr_decoration: *wlr.XdgToplevelDecorationV1,
) void {
    XdgDecoration.init(wlr_decoration);
}

fn handleNewLayerSurface(listener: *wl.Listener(*wlr.LayerSurfaceV1), wlr_layer_surface: *wlr.LayerSurfaceV1) void {
    const server = @fieldParentPtr(Server, "new_layer_surface", listener);

    log.debug(
        "new layer surface: namespace {s}, layer {s}, anchor {b:0>4}, size {},{}, margin {},{},{},{}, exclusive_zone {}",
        .{
            wlr_layer_surface.namespace,
            @tagName(wlr_layer_surface.current.layer),
            @as(u32, @bitCast(wlr_layer_surface.current.anchor)),
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
        const output = server.input_manager.defaultSeat().focused_output orelse {
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
    const server = @fieldParentPtr(Server, "request_activate", listener);

    const node_data = SceneNodeData.fromSurface(event.surface) orelse return;
    switch (node_data.data) {
        .view => |view| if (view.pending.focus == 0) {
            view.pending.urgent = true;
            server.root.applyPending();
        },
        else => |tag| {
            log.info("ignoring xdg-activation-v1 activate request of {s} surface", .{@tagName(tag)});
        },
    }
}

fn handleRequestSetCursorShape(
    _: *wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape),
    event: *wlr.CursorShapeManagerV1.event.RequestSetShape,
) void {
    // Ignore requests to set a tablet tool's cursor shape for now
    // TODO(wlroots): https://gitlab.freedesktop.org/wlroots/wlroots/-/issues/3821
    if (event.device_type == .tablet_tool) return;

    const focused_client = event.seat_client.seat.pointer_state.focused_client;

    // This can be sent by any client, so we check to make sure this one is
    // actually has pointer focus first.
    if (focused_client == event.seat_client) {
        const seat: *Seat = @ptrFromInt(event.seat_client.seat.data);
        const name = wlr.CursorShapeManagerV1.shapeName(event.shape);
        seat.cursor.setXcursor(name);
    }
}
