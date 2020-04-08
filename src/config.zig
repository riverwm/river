const std = @import("std");
const c = @import("c.zig");
const command = @import("command.zig");

const Server = @import("server.zig");

pub const Config = struct {
    const Self = @This();

    /// Width of borders in pixels
    border_width: u32 = 2,

    /// Amount of view padding in pixels
    view_padding: u32 = 10,

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
        self.view_padding = 10;

        self.keybinds = std.ArrayList(Keybind).init(allocator);

        const mod = c.WLR_MODIFIER_LOGO;
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_e, .modifiers = mod, .command = command.exitCompositor, .arg = .{ .none = {} } });

        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_j, .modifiers = mod, .command = command.focusNextView, .arg = .{ .none = {} } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_k, .modifiers = mod, .command = command.focusPrevView, .arg = .{ .none = {} } });

        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_h, .modifiers = mod, .command = command.modifyMasterFactor, .arg = .{ .float = 0.05 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_l, .modifiers = mod, .command = command.modifyMasterFactor, .arg = .{ .float = -0.05 } });

        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_Return, .modifiers = mod, .command = command.zoom, .arg = .{ .none = {} } });

        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_1, .modifiers = mod, .command = command.focusTags, .arg = .{ .uint = 1 << 0 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_2, .modifiers = mod, .command = command.focusTags, .arg = .{ .uint = 1 << 1 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_3, .modifiers = mod, .command = command.focusTags, .arg = .{ .uint = 1 << 2 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_4, .modifiers = mod, .command = command.focusTags, .arg = .{ .uint = 1 << 3 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_5, .modifiers = mod, .command = command.focusTags, .arg = .{ .uint = 1 << 4 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_6, .modifiers = mod, .command = command.focusTags, .arg = .{ .uint = 1 << 5 } });

        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_h, .modifiers = mod | c.WLR_MODIFIER_SHIFT, .command = command.modifyMasterCount, .arg = .{ .int = 1 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_l, .modifiers = mod | c.WLR_MODIFIER_SHIFT, .command = command.modifyMasterCount, .arg = .{ .int = -1 } });

        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_Return, .modifiers = mod | c.WLR_MODIFIER_SHIFT, .command = command.spawn, .arg = .{ .none = {} } });

        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_1, .modifiers = mod | c.WLR_MODIFIER_SHIFT, .command = command.setFocusedViewTags, .arg = .{ .uint = 1 << 0 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_2, .modifiers = mod | c.WLR_MODIFIER_SHIFT, .command = command.setFocusedViewTags, .arg = .{ .uint = 1 << 1 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_3, .modifiers = mod | c.WLR_MODIFIER_SHIFT, .command = command.setFocusedViewTags, .arg = .{ .uint = 1 << 2 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_4, .modifiers = mod | c.WLR_MODIFIER_SHIFT, .command = command.setFocusedViewTags, .arg = .{ .uint = 1 << 3 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_5, .modifiers = mod | c.WLR_MODIFIER_SHIFT, .command = command.setFocusedViewTags, .arg = .{ .uint = 1 << 4 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_6, .modifiers = mod | c.WLR_MODIFIER_SHIFT, .command = command.setFocusedViewTags, .arg = .{ .uint = 1 << 5 } });

        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_1, .modifiers = mod | c.WLR_MODIFIER_CTRL, .command = command.toggleTags, .arg = .{ .uint = 1 << 0 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_2, .modifiers = mod | c.WLR_MODIFIER_CTRL, .command = command.toggleTags, .arg = .{ .uint = 1 << 1 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_3, .modifiers = mod | c.WLR_MODIFIER_CTRL, .command = command.toggleTags, .arg = .{ .uint = 1 << 2 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_4, .modifiers = mod | c.WLR_MODIFIER_CTRL, .command = command.toggleTags, .arg = .{ .uint = 1 << 3 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_5, .modifiers = mod | c.WLR_MODIFIER_CTRL, .command = command.toggleTags, .arg = .{ .uint = 1 << 4 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_6, .modifiers = mod | c.WLR_MODIFIER_CTRL, .command = command.toggleTags, .arg = .{ .uint = 1 << 5 } });

        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_1, .modifiers = mod | c.WLR_MODIFIER_CTRL | c.WLR_MODIFIER_SHIFT, .command = command.toggleFocusedViewTags, .arg = .{ .uint = 1 << 0 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_2, .modifiers = mod | c.WLR_MODIFIER_CTRL | c.WLR_MODIFIER_SHIFT, .command = command.toggleFocusedViewTags, .arg = .{ .uint = 1 << 1 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_3, .modifiers = mod | c.WLR_MODIFIER_CTRL | c.WLR_MODIFIER_SHIFT, .command = command.toggleFocusedViewTags, .arg = .{ .uint = 1 << 2 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_4, .modifiers = mod | c.WLR_MODIFIER_CTRL | c.WLR_MODIFIER_SHIFT, .command = command.toggleFocusedViewTags, .arg = .{ .uint = 1 << 3 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_5, .modifiers = mod | c.WLR_MODIFIER_CTRL | c.WLR_MODIFIER_SHIFT, .command = command.toggleFocusedViewTags, .arg = .{ .uint = 1 << 4 } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_6, .modifiers = mod | c.WLR_MODIFIER_CTRL | c.WLR_MODIFIER_SHIFT, .command = command.toggleFocusedViewTags, .arg = .{ .uint = 1 << 5 } });

        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_0, .modifiers = mod, .command = command.focusTags, .arg = .{ .uint = 0xFFFFFFFF } });
        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_0, .modifiers = mod | c.WLR_MODIFIER_SHIFT, .command = command.setFocusedViewTags, .arg = .{ .uint = 0xFFFFFFFF } });

        try self.keybinds.append(Keybind{ .keysym = c.XKB_KEY_q, .modifiers = mod, .command = command.close, .arg = .{ .none = {} } });
    }
};
