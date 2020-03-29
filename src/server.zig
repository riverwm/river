const std = @import("std");
const c = @import("c.zig").c;
const util = @import("util.zig");

const DecorationManager = @import("decoration_manager.zig").DecorationManager;
const Output = @import("output.zig").Output;
const Root = @import("root.zig").Root;
const Seat = @import("seat.zig").Seat;
const View = @import("view.zig").View;

pub const Server = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,

    wl_display: *c.wl_display,
    wl_event_loop: *c.wl_event_loop,
    wlr_backend: *c.wlr_backend,
    wlr_renderer: *c.wlr_renderer,

    wlr_xdg_shell: *c.wlr_xdg_shell,

    decoration_manager: DecorationManager,
    root: Root,
    seat: Seat,

    listen_new_output: c.wl_listener,
    listen_new_xdg_surface: c.wl_listener,

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
        // a tty or wayland if WAYLAND_DISPLAY is set.
        //
        // This frees itself.when the wl_display is destroyed.
        self.wlr_backend = c.river_wlr_backend_autocreate(self.wl_display) orelse
            return error.CantCreateWlrBackend;

        // If we don't provide a renderer, autocreate makes a GLES2 renderer for us.
        // The renderer is responsible for defining the various pixel formats it
        // supports for shared memory, this configures that for clients.
        self.wlr_renderer = c.river_wlr_backend_get_renderer(self.wlr_backend) orelse
            return error.CantGetWlrRenderer;
        // TODO: Handle failure after https://github.com/swaywm/wlroots/pull/2080
        c.wlr_renderer_init_wl_display(self.wlr_renderer, self.wl_display); // orelse
        //    return error.CantInitWlDisplay;

        // These both free themselves when the wl_display is destroyed
        _ = c.wlr_compositor_create(self.wl_display, self.wlr_renderer) orelse
            return error.CantCreateWlrCompositor;
        _ = c.wlr_data_device_manager_create(self.wl_display) orelse
            return error.CantCreateWlrDataDeviceManager;

        self.wlr_xdg_shell = c.wlr_xdg_shell_create(self.wl_display) orelse
            return error.CantCreateWlrXdgShell;

        try self.decoration_manager.init(self);

        try self.root.init(self);

        try self.seat.init(self);

        // Register our listeners for new outputs and xdg_surfaces.
        self.listen_new_output.notify = handleNewOutput;
        c.wl_signal_add(&self.wlr_backend.events.new_output, &self.listen_new_output);

        self.listen_new_xdg_surface.notify = handleNewXdgSurface;
        c.wl_signal_add(&self.wlr_xdg_shell.events.new_surface, &self.listen_new_xdg_surface);
    }

    /// Free allocated memory and clean up
    pub fn destroy(self: Self) void {
        c.wl_display_destroy_clients(self.wl_display);
        c.wl_display_destroy(self.wl_display);
        self.root.destroy();
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

        // Set the WAYLAND_DISPLAY environment variable to our socket and run the
        // startup command if requested. */
        if (c.setenv("WAYLAND_DISPLAY", socket, 1) == -1) {
            return error.CantSetEnv;
        }
    }

    /// Enter the wayland event loop and block until the compositor is exited
    pub fn run(self: Self) void {
        c.wl_display_run(self.wl_display);
    }

    /// Handle all compositor keybindings
    /// Note: this is a hacky initial implementation for testing and will be rewritten eventually
    pub fn handleKeybinding(self: *Self, sym: c.xkb_keysym_t, modifiers: u32) bool {
        // This function assumes the proper modifier is held down.
        if (modifiers & @intCast(u32, c.WLR_MODIFIER_SHIFT) != 0) {
            switch (sym) {
                c.XKB_KEY_H => {
                    if (self.root.master_count < self.root.views.len) {
                        self.root.master_count += 1;
                        self.root.arrange();
                    }
                },
                c.XKB_KEY_L => {
                    if (self.root.master_count > 0) {
                        self.root.master_count -= 1;
                        self.root.arrange();
                    }
                },
                c.XKB_KEY_Return => {
                    // Spawn an instance of alacritty
                    // const argv = [_][]const u8{ "/bin/sh", "-c", "WAYLAND_DEBUG=1 alacritty" };
                    const argv = [_][]const u8{ "/bin/sh", "-c", "alacritty" };
                    const child = std.ChildProcess.init(&argv, std.heap.c_allocator) catch unreachable;
                    std.ChildProcess.spawn(child) catch unreachable;
                },
                else => return false,
            }
        } else {
            switch (sym) {
                c.XKB_KEY_e => c.wl_display_terminate(self.wl_display),
                c.XKB_KEY_j => self.root.focusNextView(),
                c.XKB_KEY_k => self.root.focusPrevView(),
                c.XKB_KEY_h => {
                    if (self.root.master_factor > 0.05) {
                        self.root.master_factor = util.max(f64, self.root.master_factor - 0.05, 0.05);
                        self.root.arrange();
                    }
                },
                c.XKB_KEY_l => {
                    if (self.root.master_factor < 0.95) {
                        self.root.master_factor = util.min(f64, self.root.master_factor + 0.05, 0.95);
                        self.root.arrange();
                    }
                },
                c.XKB_KEY_Return => {
                    if (self.root.focused_view) |current_focus| {
                        const node = @fieldParentPtr(std.TailQueue(View).Node, "data", current_focus);
                        if (node != self.root.views.first) {
                            self.root.views.remove(node);
                            self.root.views.prepend(node);
                            self.root.arrange();
                        }
                    }
                },
                else => return false,
            }
        }
        return true;
    }

    fn handleNewOutput(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const server = @fieldParentPtr(Server, "listen_new_output", listener.?);
        const wlr_output = @ptrCast(*c.wlr_output, @alignCast(@alignOf(*c.wlr_output), data));
        server.root.addOutput(wlr_output);
    }

    fn handleNewXdgSurface(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is raised when wlr_xdg_shell receives a new xdg surface from a
        // client, either a toplevel (application window) or popup.
        const server = @fieldParentPtr(Server, "listen_new_xdg_surface", listener.?);
        const wlr_xdg_surface = @ptrCast(*c.wlr_xdg_surface, @alignCast(@alignOf(*c.wlr_xdg_surface), data));

        if (wlr_xdg_surface.role != c.enum_wlr_xdg_surface_role.WLR_XDG_SURFACE_ROLE_TOPLEVEL) {
            // TODO: log
            return;
        }

        // toplevel surfaces are tracked and managed by the root
        server.root.addView(wlr_xdg_surface);
    }
};
