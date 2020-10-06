// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
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

const c = @import("c.zig");
const log = @import("log.zig");
const util = @import("util.zig");

const Config = @import("Config.zig");
const Control = @import("Control.zig");
const DecorationManager = @import("DecorationManager.zig");
const InputManager = @import("InputManager.zig");
const LayerSurface = @import("LayerSurface.zig");
const Output = @import("Output.zig");
const Root = @import("Root.zig");
const StatusManager = @import("StatusManager.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XwaylandUnmanaged = @import("XwaylandUnmanaged.zig");

wl_display: *c.wl_display,

sigint_source: *c.wl_event_source,
sigterm_source: *c.wl_event_source,

wlr_backend: *c.wlr_backend,
noop_backend: *c.wlr_backend,
listen_new_output: c.wl_listener,

wlr_xdg_shell: *c.wlr_xdg_shell,
listen_new_xdg_surface: c.wl_listener,

wlr_layer_shell: *c.wlr_layer_shell_v1,
listen_new_layer_surface: c.wl_listener,

wlr_xwayland: if (build_options.xwayland) *c.wlr_xwayland else void,
listen_new_xwayland_surface: if (build_options.xwayland) c.wl_listener else void,

decoration_manager: DecorationManager,
input_manager: InputManager,
root: Root,
config: Config,
control: Control,
status_manager: StatusManager,

pub fn init(self: *Self) !void {
    // The Wayland display is managed by libwayland. It handles accepting
    // clients from the Unix socket, managing Wayland globals, and so on.
    self.wl_display = c.wl_display_create() orelse return error.CreateDisplayError;
    errdefer c.wl_display_destroy(self.wl_display);

    // Never returns null if the display was created successfully
    const wl_event_loop = c.wl_display_get_event_loop(self.wl_display);
    self.sigint_source = c.wl_event_loop_add_signal(wl_event_loop, std.os.SIGINT, terminate, self.wl_display) orelse
        return error.AddEventSourceFailed;
    errdefer _ = c.wl_event_source_remove(self.sigint_source);
    self.sigterm_source = c.wl_event_loop_add_signal(wl_event_loop, std.os.SIGTERM, terminate, self.wl_display) orelse
        return error.AddEventSourceFailed;
    errdefer _ = c.wl_event_source_remove(self.sigterm_source);

    // The wlr_backend abstracts the input/output hardware. Autocreate chooses
    // the best option based on the environment, for example DRM when run from
    // a tty or wayland if WAYLAND_DISPLAY is set. This frees itself when the
    // wl_display is destroyed.
    self.wlr_backend = c.river_wlr_backend_autocreate(self.wl_display) orelse
        return error.CreateBackendError;

    // This backend is used to create a noop output for use when no actual
    // outputs are available. This frees itself when the wl_display is destroyed.
    self.noop_backend = c.river_wlr_noop_backend_create(self.wl_display) orelse
        return error.OutOfMemory;

    // If we don't provide a renderer, autocreate makes a GLES2 renderer for us.
    // The renderer is responsible for defining the various pixel formats it
    // supports for shared memory, this configures that for clients.
    const wlr_renderer = c.river_wlr_backend_get_renderer(self.wlr_backend).?;
    if (!c.wlr_renderer_init_wl_display(wlr_renderer, self.wl_display)) return error.DisplayInitFailed;

    self.listen_new_output.notify = handleNewOutput;
    c.wl_signal_add(&self.wlr_backend.events.new_output, &self.listen_new_output);

    const wlr_compositor = c.wlr_compositor_create(self.wl_display, wlr_renderer) orelse
        return error.OutOfMemory;

    // Set up xdg shell
    self.wlr_xdg_shell = c.wlr_xdg_shell_create(self.wl_display) orelse return error.OutOfMemory;
    self.listen_new_xdg_surface.notify = handleNewXdgSurface;
    c.wl_signal_add(&self.wlr_xdg_shell.events.new_surface, &self.listen_new_xdg_surface);

    // Set up layer shell
    self.wlr_layer_shell = c.wlr_layer_shell_v1_create(self.wl_display) orelse return error.OutOfMemory;
    self.listen_new_layer_surface.notify = handleNewLayerSurface;
    c.wl_signal_add(&self.wlr_layer_shell.events.new_surface, &self.listen_new_layer_surface);

    // Set up xwayland if built with support
    if (build_options.xwayland) {
        self.wlr_xwayland = c.wlr_xwayland_create(self.wl_display, wlr_compositor, false) orelse
            return error.CreateXwaylandError;
        self.listen_new_xwayland_surface.notify = handleNewXwaylandSurface;
        c.wl_signal_add(&self.wlr_xwayland.events.new_surface, &self.listen_new_xwayland_surface);
    }

    // Set up primary selection
    _ = c.wlr_primary_selection_v1_device_manager_create(self.wl_display);
    _ = c.wlr_gtk_primary_selection_device_manager_create(self.wl_display);

    self.config = try Config.init();
    try self.decoration_manager.init(self);
    try self.root.init(self);
    // Must be called after root is initialized
    try self.input_manager.init(self);
    try self.control.init(self);
    try self.status_manager.init(self);

    // These all free themselves when the wl_display is destroyed
    _ = c.wlr_data_device_manager_create(self.wl_display) orelse return error.OutOfMemory;
    _ = c.wlr_data_control_manager_v1_create(self.wl_display) orelse return error.OutOfMemory;
    _ = c.wlr_gamma_control_manager_v1_create(self.wl_display) orelse return error.OutOfMemory;
    _ = c.wlr_screencopy_manager_v1_create(self.wl_display) orelse return error.OutOfMemory;
    _ = c.wlr_xdg_output_manager_v1_create(self.wl_display, self.root.wlr_output_layout) orelse
        return error.OutOfMemory;
}

/// Free allocated memory and clean up
pub fn deinit(self: *Self) void {
    // Note: order is important here
    _ = c.wl_event_source_remove(self.sigint_source);
    _ = c.wl_event_source_remove(self.sigterm_source);

    if (build_options.xwayland) c.wlr_xwayland_destroy(self.wlr_xwayland);

    c.wl_display_destroy_clients(self.wl_display);

    self.root.deinit();

    c.wl_display_destroy(self.wl_display);
    c.river_wlr_backend_destory(self.noop_backend);

    self.input_manager.deinit();
    self.config.deinit();
}

/// Create the socket, start the backend, and setup the environment
pub fn start(self: Self) !void {
    const socket = c.wl_display_add_socket_auto(self.wl_display) orelse return error.AddSocketError;
    if (!c.river_wlr_backend_start(self.wlr_backend)) return error.StartBackendError;
    if (c.setenv("WAYLAND_DISPLAY", socket, 1) < 0) return error.SetenvError;
    if (build_options.xwayland) {
        if (c.setenv("DISPLAY", self.wlr_xwayland.display_name, 1) < 0) return error.SetenvError;
    }
}

/// Enter the wayland event loop and block until the compositor is exited
pub fn run(self: Self) void {
    c.wl_display_run(self.wl_display);
}

/// Handle SIGINT and SIGTERM by gracefully stopping the server
fn terminate(signal: c_int, data: ?*c_void) callconv(.C) c_int {
    const wl_display = util.voidCast(c.wl_display, data.?);
    c.wl_display_terminate(wl_display);
    return 0;
}

fn handleNewOutput(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_new_output", listener.?);
    const wlr_output = util.voidCast(c.wlr_output, data.?);
    log.debug(.server, "new output {}", .{wlr_output.name});
    self.root.addOutput(wlr_output);
}

fn handleNewXdgSurface(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is raised when wlr_xdg_shell receives a new xdg surface from a
    // client, either a toplevel (application window) or popup.
    const self = @fieldParentPtr(Self, "listen_new_xdg_surface", listener.?);
    const wlr_xdg_surface = util.voidCast(c.wlr_xdg_surface, data.?);

    if (wlr_xdg_surface.role == .WLR_XDG_SURFACE_ROLE_POPUP) {
        log.debug(.server, "new xdg_popup", .{});
        return;
    }

    log.debug(.server, "new xdg_toplevel", .{});

    // The View will add itself to the output's view stack on map
    const output = self.input_manager.defaultSeat().focused_output;
    const node = util.gpa.create(ViewStack(View).Node) catch {
        c.wl_resource_post_no_memory(wlr_xdg_surface.resource);
        return;
    };
    node.view.init(output, output.current.tags, wlr_xdg_surface);
}

/// This event is raised when the layer_shell recieves a new surface from a client.
fn handleNewLayerSurface(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_new_layer_surface", listener.?);
    const wlr_layer_surface = util.voidCast(c.wlr_layer_surface_v1, data.?);

    log.debug(
        .server,
        "New layer surface: namespace {}, layer {}, anchor {}, size {}x{}, margin ({},{},{},{}), exclusive_zone {}",
        .{
            wlr_layer_surface.namespace,
            wlr_layer_surface.client_pending.layer,
            wlr_layer_surface.client_pending.anchor,
            wlr_layer_surface.client_pending.desired_width,
            wlr_layer_surface.client_pending.desired_height,
            wlr_layer_surface.client_pending.margin.top,
            wlr_layer_surface.client_pending.margin.right,
            wlr_layer_surface.client_pending.margin.bottom,
            wlr_layer_surface.client_pending.margin.left,
            wlr_layer_surface.client_pending.exclusive_zone,
        },
    );

    // If the new layer surface does not have an output assigned to it, use the
    // first output or close the surface if none are available.
    if (wlr_layer_surface.output == null) {
        const output = self.input_manager.defaultSeat().focused_output;
        if (output == &self.root.noop_output) {
            log.err(.server, "no output available for layer surface '{s}'", .{wlr_layer_surface.namespace});
            c.wlr_layer_surface_v1_close(wlr_layer_surface);
            return;
        }

        log.debug(
            .server,
            "new layer surface had null output, assigning it to output '{s}'",
            .{output.wlr_output.name},
        );
        wlr_layer_surface.output = output.wlr_output;
    }

    // The layer surface will add itself to the proper list of the output on map
    const output = util.voidCast(Output, wlr_layer_surface.output.*.data.?);
    const node = util.gpa.create(std.TailQueue(LayerSurface).Node) catch {
        c.wl_resource_post_no_memory(wlr_layer_surface.resource);
        return;
    };
    node.data.init(output, wlr_layer_surface);
}

fn handleNewXwaylandSurface(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_new_xwayland_surface", listener.?);
    const wlr_xwayland_surface = util.voidCast(c.wlr_xwayland_surface, data.?);

    if (wlr_xwayland_surface.override_redirect) {
        log.debug(.server, "new unmanaged xwayland surface", .{});
        // The unmanged surface will add itself to the list of unmanaged views
        // in Root when it is mapped.
        const node = util.gpa.create(std.TailQueue(XwaylandUnmanaged).Node) catch return;
        node.data.init(&self.root, wlr_xwayland_surface);
        return;
    }

    log.debug(
        .server,
        "new xwayland surface: title '{}', class '{}'",
        .{ wlr_xwayland_surface.title, wlr_xwayland_surface.class },
    );

    // The View will add itself to the output's view stack on map
    const output = self.input_manager.defaultSeat().focused_output;
    const node = util.gpa.create(ViewStack(View).Node) catch return;
    node.view.init(output, output.current.tags, wlr_xwayland_surface);
}
