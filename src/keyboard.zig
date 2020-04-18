const std = @import("std");
const c = @import("c.zig");

const Log = @import("log.zig").Log;
const Seat = @import("seat.zig").Seat;

pub const Keyboard = struct {
    const Self = @This();

    seat: *Seat,
    device: *c.wlr_input_device,
    wlr_keyboard: *c.wlr_keyboard,

    listen_key: c.wl_listener,
    listen_modifiers: c.wl_listener,

    pub fn init(self: *Self, seat: *Seat, device: *c.wlr_input_device) !void {
        self.seat = seat;
        self.device = device;
        self.wlr_keyboard = device.unnamed_133.keyboard;

        // We need to prepare an XKB keymap and assign it to the keyboard. This
        // assumes the defaults (e.g. layout = "us").
        const rules = c.xkb_rule_names{
            .rules = null,
            .model = null,
            .layout = null,
            .variant = null,
            .options = null,
        };
        const context = c.xkb_context_new(c.enum_xkb_context_flags.XKB_CONTEXT_NO_FLAGS) orelse
            return error.CantCreateXkbContext;
        defer c.xkb_context_unref(context);

        const keymap = c.xkb_keymap_new_from_names(
            context,
            &rules,
            c.enum_xkb_keymap_compile_flags.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse
            return error.CantCreateXkbKeymap;
        defer c.xkb_keymap_unref(keymap);

        // TODO: handle failure after https://github.com/swaywm/wlroots/pull/2081
        c.wlr_keyboard_set_keymap(self.wlr_keyboard, keymap);
        c.wlr_keyboard_set_repeat_info(self.wlr_keyboard, 25, 600);

        // Setup listeners for keyboard events
        self.listen_key.notify = handleKey;
        c.wl_signal_add(&self.wlr_keyboard.events.key, &self.listen_key);

        self.listen_modifiers.notify = handleModifiers;
        c.wl_signal_add(&self.wlr_keyboard.events.modifiers, &self.listen_modifiers);
    }

    fn handleKey(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is raised when a key is pressed or released.
        const keyboard = @fieldParentPtr(Keyboard, "listen_key", listener.?);
        const event = @ptrCast(
            *c.wlr_event_keyboard_key,
            @alignCast(@alignOf(*c.wlr_event_keyboard_key), data),
        );

        const wlr_keyboard: *c.wlr_keyboard = keyboard.device.unnamed_133.keyboard;

        // Translate libinput keycode -> xkbcommon
        const keycode = event.keycode + 8;

        // Get a list of keysyms as xkb reports them
        var translated_keysyms: ?[*]c.xkb_keysym_t = undefined;
        const translated_keysyms_len = c.xkb_state_key_get_syms(
            wlr_keyboard.xkb_state,
            keycode,
            &translated_keysyms,
        );

        // Get a list of keysyms ignoring modifiers (e.g. 1 instead of !)
        // Important for bindings like Mod+Shift+1
        var raw_keysyms: ?[*]c.xkb_keysym_t = undefined;
        const layout_index = c.xkb_state_key_get_layout(wlr_keyboard.xkb_state, keycode);
        const raw_keysyms_len = c.xkb_keymap_key_get_syms_by_level(
            wlr_keyboard.keymap,
            keycode,
            layout_index,
            0,
            &raw_keysyms,
        );

        var handled = false;
        // TODO: These modifiers aren't properly handled, see sway's code
        const modifiers = c.wlr_keyboard_get_modifiers(wlr_keyboard);
        if (event.state == c.enum_wlr_key_state.WLR_KEY_PRESSED) {
            var i: usize = 0;
            while (i < translated_keysyms_len) : (i += 1) {
                if (keyboard.handleBuiltinKeybind(translated_keysyms.?[i])) {
                    handled = true;
                    break;
                } else if (keyboard.seat.handleKeybinding(translated_keysyms.?[i], modifiers)) {
                    handled = true;
                    break;
                }
            }
            if (!handled) {
                i = 0;
                while (i < raw_keysyms_len) : (i += 1) {
                    if (keyboard.handleBuiltinKeybind(raw_keysyms.?[i])) {
                        handled = true;
                        break;
                    } else if (keyboard.seat.handleKeybinding(raw_keysyms.?[i], modifiers)) {
                        handled = true;
                        break;
                    }
                }
            }
        }

        if (!handled) {
            // Otherwise, we pass it along to the client.
            const wlr_seat = keyboard.seat.wlr_seat;
            c.wlr_seat_set_keyboard(wlr_seat, keyboard.device);
            c.wlr_seat_keyboard_notify_key(
                wlr_seat,
                event.time_msec,
                event.keycode,
                @intCast(u32, @enumToInt(event.state)),
            );
        }
    }

    fn handleModifiers(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is raised when a modifier key, such as shift or alt, is
        // pressed. We simply communicate this to the client. */
        const keyboard = @fieldParentPtr(Keyboard, "listen_modifiers", listener.?);

        // A seat can only have one keyboard, but this is a limitation of the
        // Wayland protocol - not wlroots. We assign all connected keyboards to the
        // same seat. You can swap out the underlying wlr_keyboard like this and
        // wlr_seat handles this transparently.
        c.wlr_seat_set_keyboard(keyboard.seat.wlr_seat, keyboard.device);

        // Send modifiers to the client.
        c.wlr_seat_keyboard_notify_modifiers(
            keyboard.seat.wlr_seat,
            &keyboard.wlr_keyboard.modifiers,
        );
    }

    /// Handle any builtin, harcoded compsitor bindings such as VT switching.
    /// Returns true if the keysym was handled.
    fn handleBuiltinKeybind(self: Self, keysym: c.xkb_keysym_t) bool {
        if (keysym >= c.XKB_KEY_XF86Switch_VT_1 and keysym <= c.XKB_KEY_XF86Switch_VT_12) {
            Log.Debug.log("Switch VT keysym received", .{});
            const wlr_backend = self.seat.input_manager.server.wlr_backend;
            if (c.river_wlr_backend_is_multi(wlr_backend)) {
                if (c.river_wlr_backend_get_session(wlr_backend)) |session| {
                    const vt = keysym - c.XKB_KEY_XF86Switch_VT_1 + 1;
                    Log.Debug.log("Switching to VT {}", .{vt});
                    _ = c.wlr_session_change_vt(session, vt);
                }
            }
            return true;
        }
        return false;
    }
};
