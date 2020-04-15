const std = @import("std");
const c = @import("c.zig");
const command = @import("command.zig");

const Server = @import("server.zig");

pub const Config = struct {
    const Self = @This();

    /// Width of borders in pixels
    border_width: u32,

    /// Amount of view padding in pixels
    view_padding: u32,

    /// Amount of padding arount the outer edge of the layout in pixels
    outer_padding: u32,

    const Keybind = struct {
        keysym: c.xkb_keysym_t,
        modifiers: u32,
        command: command.Command,
        arg: command.Arg,
    };

    /// All user-defined keybindings
    keybinds: std.ArrayList(Keybind),

    pub fn init(self: *Self, allocator: *std.mem.Allocator) !void {
        self.border_width = 2;
        self.view_padding = 8;
        self.outer_padding = 8;

        self.keybinds = std.ArrayList(Keybind).init(allocator);

        const mod = c.WLR_MODIFIER_LOGO;

        // Mod+Shift+Return to start an instance of alacritty
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_Return, .modifiers = mod | c.WLR_MODIFIER_SHIFT, .command = command.spawn, .arg = .{ .str = "alacritty" } });

        // Mod+Q to close the focused view
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_q, .modifiers = mod, .command = command.close, .arg = .{ .none = {} } });

        // Mod+E to exit river
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_e, .modifiers = mod, .command = command.exitCompositor, .arg = .{ .none = {} } });

        // Mod+J and Mod+K to focus the next/previous view in the layout stack
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_j, .modifiers = mod, .command = command.focusNextView, .arg = .{ .none = {} } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_k, .modifiers = mod, .command = command.focusPrevView, .arg = .{ .none = {} } });

        // Mod+Return to bump the focused view to the top of the layout stack, making it the new master
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_Return, .modifiers = mod, .command = command.zoom, .arg = .{ .none = {} } });

        // Mod+H and Mod+L to increase/decrease the width of the master column
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_h, .modifiers = mod, .command = command.modifyMasterFactor, .arg = .{ .float = 0.05 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_l, .modifiers = mod, .command = command.modifyMasterFactor, .arg = .{ .float = -0.05 } });

        // Mod+Shift+H and Mod+Shift+L to increment/decrement the number of master views in the layout
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_h, .modifiers = mod | c.WLR_MODIFIER_SHIFT, .command = command.modifyMasterCount, .arg = .{ .int = 1 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_l, .modifiers = mod | c.WLR_MODIFIER_SHIFT, .command = command.modifyMasterCount, .arg = .{ .int = -1 } });

        comptime var i = 0;
        inline while (i < 9) : (i += 1) {
            // Mod+[1-9] to focus tag [1-9]
            try self.keybinds.append(Keybind{
                .keysym = c.XKB_KEY_1 + i,
                .modifiers = mod,
                .command = command.focusTags,
                .arg = .{ .uint = 1 << i },
            });
            // Mod+Shift+[1-9] to tag focused view with tag [1-9]
            try self.keybinds.append(Keybind{
                .keysym = c.XKB_KEY_1 + i,
                .modifiers = mod | c.WLR_MODIFIER_SHIFT,
                .command = command.setFocusedViewTags,
                .arg = .{ .uint = 1 << i },
            });
            // Mod+Ctrl+[1-9] to toggle focus of tag [1-9]
            try self.keybinds.append(Keybind{
                .keysym = c.XKB_KEY_1 + i,
                .modifiers = mod | c.WLR_MODIFIER_CTRL,
                .command = command.toggleTags,
                .arg = .{ .uint = 1 << i },
            });
            // Mod+Shift+Ctrl+[1-9] to toggle tag [1-9] of focused view
            try self.keybinds.append(Keybind{
                .keysym = c.XKB_KEY_1 + i,
                .modifiers = mod | c.WLR_MODIFIER_CTRL | c.WLR_MODIFIER_SHIFT,
                .command = command.toggleFocusedViewTags,
                .arg = .{ .uint = 1 << i },
            });
        }

        // Mod+0 to focus all tags
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_0, .modifiers = mod, .command = command.focusTags, .arg = .{ .uint = 0xFFFFFFFF } });

        // Mod+Shift+0 to tag focused view with all tags
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_0, .modifiers = mod | c.WLR_MODIFIER_SHIFT, .command = command.setFocusedViewTags, .arg = .{ .uint = 0xFFFFFFFF } });

        // Mod+Period and Mod+Comma to focus the next/previous output
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_period, .modifiers = mod, .command = command.focusNextOutput, .arg = .{ .none = {} } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_comma, .modifiers = mod, .command = command.focusPrevOutput, .arg = .{ .none = {} } });
    }
};
