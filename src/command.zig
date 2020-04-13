const std = @import("std");
const c = @import("c.zig");

const Log = @import("log.zig").Log;
const Seat = @import("seat.zig").Seat;
const View = @import("view.zig").View;
const ViewStack = @import("view_stack.zig").ViewStack;

pub const Arg = union {
    int: i32,
    uint: u32,
    float: f64,
    str: []const u8,
    none: void,
};

pub const Command = fn (seat: *Seat, arg: Arg) void;

/// Exit the compositor, terminating the wayland session.
pub fn exitCompositor(seat: *Seat, arg: Arg) void {
    c.wl_display_terminate(seat.input_manager.server.wl_display);
}

/// Focus the next visible view in the stack, wrapping if needed. Does
/// nothing if there is only one view in the stack.
pub fn focusNextView(seat: *Seat, arg: Arg) void {
    // FIXME: this need to be rewritten the next commit adding a focus stack
    //const output = self.focusedOutput();
    //if (self.focused_view) |current_focus| {
    //    // If there is a currently focused view, focus the next visible view in the stack.
    //    const current_node = @fieldParentPtr(ViewStack(View).Node, "view", current_focus);
    //    var it = ViewStack(View).iterator(current_node, output.current_focused_tags);
    //    // Skip past the current node
    //    _ = it.next();
    //    // Focus the next visible node if there is one
    //    if (it.next()) |node| {
    //        node.view.focus(node.view.wlr_xdg_surface.surface);
    //        return;
    //    }
    //}

    //// There is either no currently focused view or the last visible view in the
    //// stack is focused and we need to wrap.
    //var it = ViewStack(View).iterator(output.views.first, output.current_focused_tags);
    //if (it.next()) |node| {
    //    node.view.focus(node.view.wlr_xdg_surface.surface);
    //} else {
    //    // Otherwise clear the focus since there are no visible views
    //    self.clearFocus();
    //}
}

/// Focus the previous view in the stack, wrapping if needed. Does nothing
/// if there is only one view in the stack.
pub fn focusPrevView(seat: *Seat, arg: Arg) void {
    // FIXME: this need to be rewritten the next commit adding a focus stack
    //const output = self.focusedOutput();
    //if (self.focused_view) |current_focus| {
    //    // If there is a currently focused view, focus the previous visible view in the stack.
    //    const current_node = @fieldParentPtr(ViewStack(View).Node, "view", current_focus);
    //    var it = ViewStack(View).reverseIterator(current_node, output.current_focused_tags);
    //    // Skip past the current node
    //    _ = it.next();
    //    // Focus the previous visible node if there is one
    //    if (it.next()) |node| {
    //        node.view.focus(node.view.wlr_xdg_surface.surface);
    //        return;
    //    }
    //}

    //// There is either no currently focused view or the first visible view in the
    //// stack is focused and we need to wrap.
    //var it = ViewStack(View).reverseIterator(output.views.last, output.current_focused_tags);
    //if (it.next()) |node| {
    //    node.view.focus(node.view.wlr_xdg_surface.surface);
    //} else {
    //    // Otherwise clear the focus since there are no visible views
    //    self.clearFocus();
    //}
}

/// Modify the number of master views
pub fn modifyMasterCount(seat: *Seat, arg: Arg) void {
    const delta = arg.int;
    const root = &seat.input_manager.server.root;
    const output = root.focusedOutput();
    output.master_count = @intCast(
        u32,
        std.math.max(0, @intCast(i32, output.master_count) + delta),
    );
    root.arrange();
}

/// Modify the percent of the width of the screen that the master views occupy.
pub fn modifyMasterFactor(seat: *Seat, arg: Arg) void {
    const delta = arg.float;
    const root = &seat.input_manager.server.root;
    const output = root.focusedOutput();
    const new_master_factor = std.math.min(
        std.math.max(output.master_factor + delta, 0.05),
        0.95,
    );
    if (new_master_factor != output.master_factor) {
        output.master_factor = new_master_factor;
        root.arrange();
    }
}

/// Bump the focused view to the top of the stack.
/// TODO: if the top of the stack is focused, bump the next visible view.
pub fn zoom(seat: *Seat, arg: Arg) void {
    // FIXME rewrite after next commit adding focus stack
    //if (server.root.focused_view) |current_focus| {
    //    const output = server.root.focusedOutput();
    //    const node = @fieldParentPtr(ViewStack(View).Node, "view", current_focus);
    //    if (node != output.views.first) {
    //        output.views.remove(node);
    //        output.views.push(node);
    //        server.root.arrange();
    //    }
    //}
}

/// Switch focus to the passed tags.
pub fn focusTags(seat: *Seat, arg: Arg) void {
    const tags = arg.uint;
    const root = &seat.input_manager.server.root;
    const output = root.focusedOutput();
    output.pending_focused_tags = tags;
    root.arrange();
}

/// Toggle focus of the passsed tags.
pub fn toggleTags(seat: *Seat, arg: Arg) void {
    const tags = arg.uint;
    const root = &seat.input_manager.server.root;
    const output = root.focusedOutput();
    const new_focused_tags = output.current_focused_tags ^ tags;
    if (new_focused_tags != 0) {
        output.pending_focused_tags = new_focused_tags;
        root.arrange();
    }
}

/// Set the tags of the focused view.
pub fn setFocusedViewTags(seat: *Seat, arg: Arg) void {
    // FIXME
    //const tags = arg.uint;
    //if (server.root.focused_view) |view| {
    //    if (view.current_tags != tags) {
    //        view.pending_tags = tags;
    //        server.root.arrange();
    //    }
    //}
}

/// Toggle the passed tags of the focused view
pub fn toggleFocusedViewTags(seat: *Seat, arg: Arg) void {
    // FIXME: rewrite afet next commit adding focus stack
    //const tags = arg.uint;
    //if (server.root.focused_view) |view| {
    //    const new_tags = view.current_tags ^ tags;
    //    if (new_tags != 0) {
    //        view.pending_tags = new_tags;
    //        server.root.arrange();
    //    }
    //}
}

/// Spawn a program.
/// TODO: make this take a program as a paramter and spawn that
pub fn spawn(seat: *Seat, arg: Arg) void {
    const cmd = arg.str;

    const argv = [_][]const u8{ "/bin/sh", "-c", cmd };
    const child = std.ChildProcess.init(&argv, std.heap.c_allocator) catch |err| {
        Log.Error.log("Failed to execute {}: {}", .{ cmd, err });
        return;
    };
    std.ChildProcess.spawn(child) catch |err| {
        Log.Error.log("Failed to execute {}: {}", .{ cmd, err });
        return;
    };
}

/// Close the focused view, if any.
pub fn close(seat: *Seat, arg: Arg) void {
    // FIXME: see above
    //if (server.root.focused_view) |view| {
    //    view.close();
    //}
}
