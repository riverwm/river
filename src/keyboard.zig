const std = @import("std");
const c = @import("c.zig").c;

const Seat = @import("seat.zig").Seat;

pub const Keyboard = struct {
    seat: *Seat,
    device: *c.wlr_input_device,
    wlr_keyboard: *c.wlr_keyboard,

    listen_modifiers: c.wl_listener,
    listen_key: c.wl_listener,

    pub fn init(self: *@This(), seat: *Seat, device: *c.wlr_input_device) !void {
        self.seat = seat;
        self.device = device;
        self.wlr_keyboard = device.unnamed_37.keyboard;

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
        self.listen_modifiers.notify = handle_modifiers;
        c.wl_signal_add(&self.wlr_keyboard.events.modifiers, &self.listen_modifiers);

        self.listen_key.notify = handle_key;
        c.wl_signal_add(&self.wlr_keyboard.events.key, &self.listen_key);
    }

    fn handle_modifiers(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is raised when a modifier key, such as shift or alt, is
        // pressed. We simply communicate this to the client. */
        var keyboard = @fieldParentPtr(Keyboard, "listen_modifiers", listener.?);

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

    fn handle_key(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is raised when a key is pressed or released.
        const keyboard = @fieldParentPtr(Keyboard, "listen_key", listener.?);
        const event = @ptrCast(
            *c.wlr_event_keyboard_key,
            @alignCast(@alignOf(*c.wlr_event_keyboard_key), data),
        );

        const wlr_keyboard: *c.wlr_keyboard = keyboard.device.unnamed_37.keyboard;

        // Translate libinput keycode -> xkbcommon
        const keycode = event.keycode + 8;
        // Get a list of keysyms based on the keymap for this keyboard
        var syms: ?[*]c.xkb_keysym_t = undefined;
        const nsyms = c.xkb_state_key_get_syms(wlr_keyboard.xkb_state, keycode, &syms);

        var handled = false;
        const modifiers = c.wlr_keyboard_get_modifiers(wlr_keyboard);
        if (modifiers & @intCast(u32, c.WLR_MODIFIER_LOGO) != 0 and
            event.state == c.enum_wlr_key_state.WLR_KEY_PRESSED)
        {
            // If mod is held down and this button was _pressed_, we attempt to
            // process it as a compositor keybinding.
            var i: usize = 0;
            while (i < nsyms) {
                handled = keyboard.seat.server.handle_keybinding(syms.?[i]);
                if (handled) {
                    break;
                }
                i += 1;
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
};
