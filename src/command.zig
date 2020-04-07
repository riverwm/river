const std = @import("std");
const c = @import("c.zig");

const Server = @import("server.zig").Server;
const ViewStack = @import("view_stack.zig").ViewStack;

/// Exit the compositor, terminating the wayland session.
pub fn exitCompositor(server: *Server) void {
    c.wl_display_terminate(server.wl_display);
}

/// Shift focus to the next visible view, wrapping if needed.
pub fn focusNextView(server: *Server) void {
    server.root.focusNextView();
}

/// Shift focus to the previous visible view, wrapping if needed.
pub fn focusPrevView(server: *Server) void {
    server.root.focusPrevView();
}

/// Modify the number of master views
pub fn modifyMasterCount(server: *Server, delta: i32) void {
    server.root.master_count = @intCast(u32, std.math.max(
        0,
        @intCast(i32, server.root.master_count) + delta,
    ));
    server.root.arrange();
}

/// Modify the percent of the width of the screen that the master views occupy.
pub fn modifyMasterFactor(server: *Server, delta: f64) void {
    const new_master_factor = std.math.min(
        std.math.max(server.root.master_factor + delta, 0.05),
        0.95,
    );
    if (new_master_factor != server.root.master_factor) {
        server.root.master_factor = new_master_factor;
        server.root.arrange();
    }
}

/// Bump the focused view to the top of the stack.
/// TODO: if the top of the stack is focused, bump the next visible view.
pub fn zoom(server: *Server) void {
    if (server.root.focused_view) |current_focus| {
        const node = @fieldParentPtr(ViewStack.Node, "view", current_focus);
        if (node != server.root.views.first) {
            server.root.views.remove(node);
            server.root.views.push(node);
            server.root.arrange();
        }
    }
}

/// Switch focus to the passed tags.
pub fn focusTags(server: *Server, tags: u32) void {
    server.root.pending_focused_tags = tags;
    server.root.arrange();
}

/// Set the tags of the focused view.
pub fn setFocusedViewTags(server: *Server, tags: u32) void {
    if (server.root.focused_view) |view| {
        if (view.current_tags != tags) {
            view.pending_tags = tags;
            server.root.arrange();
        }
    }
}

/// Spawn a program.
/// TODO: make this take a program as a paramter and spawn that
pub fn spawn(server: *Server) void {
    const argv = [_][]const u8{ "/bin/sh", "-c", "alacritty" };
    const child = std.ChildProcess.init(&argv, std.heap.c_allocator) catch unreachable;
    std.ChildProcess.spawn(child) catch unreachable;
}
