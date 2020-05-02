const Self = @This();

const std = @import("std");

const c = @import("c.zig");

const Config = @import("config.zig");
const DecorationManager = @import("decoration_manager.zig");
const InputManager = @import("input_manager.zig");
const Log = @import("log.zig").Log;
const Output = @import("output.zig");
const Root = @import("root.zig").Root;
const View = @import("view.zig").View;
const ViewStack = @import("view_stack.zig").ViewStack;

allocator: *std.mem.Allocator,

wl_display: *c.wl_display,
wl_event_loop: *c.wl_event_loop,
wlr_backend: *c.wlr_backend,
noop_backend: *c.wlr_backend,
wlr_renderer: *c.wlr_renderer,

wlr_xdg_shell: *c.wlr_xdg_shell,
wlr_layer_shell: *c.wlr_layer_shell_v1,

decoration_manager: DecorationManager,
input_manager: InputManager,
root: Root,
config: Config,

listen_new_output: c.wl_listener,
listen_new_xdg_surface: c.wl_listener,
listen_new_layer_surface: c.wl_listener,

pub fn init(self: *Self, allocator: *std.mem.Allocator) !void {
    self.allocator = allocator;

    // The Wayland display is managed by libwayland. It handles accepting
    // clients from the Unix socket, managing Wayland globals, and so on.
    self.wl_display = c.wl_display_create() orelse
        return error.CantCreateWlDisplay;
    errdefer c.wl_display_destroy(self.wl_display);

    // Should never return null if the display was created successfully
    self.wl_event_loop = c.wl_display_get_event_loop(self.wl_display) orelse
        return error.CantGetEventLoop;

    // The wlr_backend abstracts the input/output hardware. Autocreate chooses
    // the best option based on the environment, for example DRM when run from
    // a tty or wayland if WAYLAND_DISPLAY is set. This frees itself when the
    // wl_display is destroyed.
    self.wlr_backend = c.river_wlr_backend_autocreate(self.wl_display) orelse
        return error.CantCreateWlrBackend;

    // This backend is used to create a noop output for use when no actual
    // outputs are available. This frees itself when the wl_display is destroyed.
    self.noop_backend = c.river_wlr_noop_backend_create(self.wl_display) orelse
        return error.CantCreateNoopBackend;

    // If we don't provide a renderer, autocreate makes a GLES2 renderer for us.
    // The renderer is responsible for defining the various pixel formats it
    // supports for shared memory, this configures that for clients.
    self.wlr_renderer = c.river_wlr_backend_get_renderer(self.wlr_backend) orelse
        return error.CantGetWlrRenderer;
    // TODO: Handle failure after https://github.com/swaywm/wlroots/pull/2080
    c.wlr_renderer_init_wl_display(self.wlr_renderer, self.wl_display); // orelse
    //    return error.CantInitWlDisplay;

    self.wlr_xdg_shell = c.wlr_xdg_shell_create(self.wl_display) orelse
        return error.CantCreateWlrXdgShell;

    self.wlr_layer_shell = c.wlr_layer_shell_v1_create(self.wl_display) orelse
        return error.CantCreateWlrLayerShell;

    try self.decoration_manager.init(self);
    try self.root.init(self);
    // Must be called after root is initialized
    try self.input_manager.init(self);
    try self.config.init(self.allocator);

    // These all free themselves when the wl_display is destroyed
    _ = c.wlr_compositor_create(self.wl_display, self.wlr_renderer) orelse
        return error.CantCreateWlrCompositor;
    _ = c.wlr_data_device_manager_create(self.wl_display) orelse
        return error.CantCreateWlrDataDeviceManager;
    _ = c.wlr_screencopy_manager_v1_create(self.wl_display) orelse
        return error.CantCreateWlrScreencopyManager;
    _ = c.wlr_xdg_output_manager_v1_create(self.wl_display, self.root.wlr_output_layout) orelse
        return error.CantCreateWlrOutputManager;

    // Register listeners for events on our globals
    self.listen_new_output.notify = handleNewOutput;
    c.wl_signal_add(&self.wlr_backend.events.new_output, &self.listen_new_output);

    self.listen_new_xdg_surface.notify = handleNewXdgSurface;
    c.wl_signal_add(&self.wlr_xdg_shell.events.new_surface, &self.listen_new_xdg_surface);

    self.listen_new_layer_surface.notify = handleNewLayerSurface;
    c.wl_signal_add(&self.wlr_layer_shell.events.new_surface, &self.listen_new_layer_surface);
}

/// Free allocated memory and clean up
pub fn deinit(self: *Self) void {
    // Note: order is important here
    c.wl_display_destroy_clients(self.wl_display);
    c.wl_display_destroy(self.wl_display);
    self.input_manager.deinit();
    self.root.deinit();
}

/// Create the socket, set WAYLAND_DISPLAY, and start the backend
pub fn start(self: Self) !void {
    // Add a Unix socket to the Wayland display.
    const socket = c.wl_display_add_socket_auto(self.wl_display) orelse
        return error.CantAddSocket;

    // Start the backend. This will enumerate outputs and inputs, become the DRM
    // master, etc
    if (!c.river_wlr_backend_start(self.wlr_backend)) {
        return error.CantStartBackend;
    }

    // Set the WAYLAND_DISPLAY environment variable to our socket
    if (c.setenv("WAYLAND_DISPLAY", socket, 1) == -1) {
        return error.CantSetEnv;
    }
}

/// Enter the wayland event loop and block until the compositor is exited
pub fn run(self: Self) void {
    c.wl_display_run(self.wl_display);
}

fn handleNewOutput(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_new_output", listener.?);
    const wlr_output = @ptrCast(*c.wlr_output, @alignCast(@alignOf(*c.wlr_output), data));
    Log.Debug.log("New output {}", .{wlr_output.name});
    self.root.addOutput(wlr_output);
}

fn handleNewXdgSurface(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    // This event is raised when wlr_xdg_shell receives a new xdg surface from a
    // client, either a toplevel (application window) or popup.
    const self = @fieldParentPtr(Self, "listen_new_xdg_surface", listener.?);
    const wlr_xdg_surface = @ptrCast(*c.wlr_xdg_surface, @alignCast(@alignOf(*c.wlr_xdg_surface), data));

    if (wlr_xdg_surface.role == .WLR_XDG_SURFACE_ROLE_POPUP) {
        Log.Debug.log("New xdg_popup", .{});
        return;
    }

    Log.Debug.log("New xdg_toplevel", .{});

    self.input_manager.default_seat.focused_output.addView(wlr_xdg_surface);
}

/// This event is raised when the layer_shell recieves a new surface from a client.
fn handleNewLayerSurface(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_new_layer_surface", listener.?);
    const wlr_layer_surface = @ptrCast(
        *c.wlr_layer_surface_v1,
        @alignCast(@alignOf(*c.wlr_layer_surface_v1), data),
    );

    Log.Debug.log(
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
        if (self.root.outputs.first) |node| {
            const output = &node.data;
            Log.Debug.log(
                "New layer surface had null output, assigning it to output {}",
                .{output.wlr_output.name},
            );
            wlr_layer_surface.output = output.wlr_output;
        } else {
            Log.Error.log(
                "No output available for layer surface '{}'",
                .{wlr_layer_surface.namespace},
            );
            c.wlr_layer_surface_v1_close(wlr_layer_surface);
            return;
        }
    }

    const output = @ptrCast(*Output, @alignCast(@alignOf(*Output), wlr_layer_surface.output.*.data));
    output.addLayerSurface(wlr_layer_surface) catch unreachable;
}
