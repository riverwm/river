const std = @import("std");
const c = @import("c.zig");

const Server = @import("server.zig").Server;
const ViewStack = @import("view_stack.zig").ViewStack;

pub const Arg = union {
    int: i32,
    uint: u32,
    float: f64,
    none: void,
};

pub const Command = fn (server: *Server, arg: Arg) void;

/// Exit the compositor, terminating the wayland session.
pub fn exitCompositor(server: *Server, arg: Arg) void {
    c.wl_display_terminate(server.wl_display);
}

/// Shift focus to the next visible view, wrapping if needed.
pub fn focusNextView(server: *Server, arg: Arg) void {
    server.root.focusNextView();
}

/// Shift focus to the previous visible view, wrapping if needed.
pub fn focusPrevView(server: *Server, arg: Arg) void {
    server.root.focusPrevView();
}

/// Modify the number of master views
pub fn modifyMasterCount(server: *Server, arg: Arg) void {
    const delta = arg.int;
    server.root.master_count = @intCast(u32, std.math.max(
        0,
        @intCast(i32, server.root.master_count) + delta,
    ));
    server.root.arrange();
}

/// Modify the percent of the width of the screen that the master views occupy.
pub fn modifyMasterFactor(server: *Server, arg: Arg) void {
    const delta = arg.float;
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
pub fn zoom(server: *Server, arg: Arg) void {
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
pub fn focusTags(server: *Server, arg: Arg) void {
    const tags = arg.uint;
    server.root.pending_focused_tags = tags;
    server.root.arrange();
}

/// Set the tags of the focused view.
pub fn setFocusedViewTags(server: *Server, arg: Arg) void {
    const tags = arg.uint;
    if (server.root.focused_view) |view| {
        if (view.current_tags != tags) {
            view.pending_tags = tags;
            server.root.arrange();
        }
    }
}

/// Spawn a program.
/// TODO: make this take a program as a paramter and spawn that
pub fn spawn(server: *Server, arg: Arg) void {
    const argv = [_][]const u8{ "/bin/sh", "-c", "alacritty" };
    const child = std.ChildProcess.init(&argv, std.heap.c_allocator) catch unreachable;
    std.ChildProcess.spawn(child) catch unreachable;
}
