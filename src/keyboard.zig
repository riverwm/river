const std = @import("std");
const c = @import("c.zig").c;

const Keyboard = struct {
    seat: *Seat,
    device: *c.wlr_input_device,

    listen_modifiers: c.wl_listener,
    listen_key: c.wl_listener,

    pub fn init(seat: *Seat, device: *c.wlr_input_device) @This() {
        var keyboard = @This(){
            .seat = seat,
            .device = device,

            .listen_modifiers = c.wl_listener{
                .link = undefined,
                .notify = handle_modifiers,
            },
            .listen_key = c.wl_listener{
                .link = undefined,
                .notify = handle_key,
            },
        };

        // We need to prepare an XKB keymap and assign it to the keyboard. This
        // assumes the defaults (e.g. layout = "us").
        const rules = c.xkb_rule_names{
            .rules = null,
            .model = null,
            .layout = null,
            .variant = null,
            .options = null,
        };
        const context = c.xkb_context_new(c.enum_xkb_context_flags.XKB_CONTEXT_NO_FLAGS);
        defer c.xkb_context_unref(context);

        const keymap = man_c.xkb_map_new_from_names(
            context,
            &rules,
            c.enum_xkb_keymap_compile_flags.XKB_KEYMAP_COMPILE_NO_FLAGS,
        );
        defer c.xkb_keymap_unref(keymap);

        var keyboard_device = device.*.unnamed_37.keyboard;
        c.wlr_keyboard_set_keymap(keyboard_device, keymap);
        c.wlr_keyboard_set_repeat_info(keyboard_device, 25, 600);

        // Setup listeners for keyboard events
        c.wl_signal_add(&keyboard_device.*.events.modifiers, &keyboard.*.listen_modifiers);
        c.wl_signal_add(&keyboard_device.*.events.key, &keyboard.*.listen_key);

        return keyboard;
    }

    fn handle_modifiers(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is raised when a modifier key, such as shift or alt, is
        // pressed. We simply communicate this to the client. */
        var keyboard = @fieldParentPtr(Keyboard, "listen_modifiers", listener);

        // A seat can only have one keyboard, but this is a limitation of the
        // Wayland protocol - not wlroots. We assign all connected keyboards to the
        // same seat. You can swap out the underlying wlr_keyboard like this and
        // wlr_seat handles this transparently.
        c.wlr_seat_set_keyboard(keyboard.*.server.*.seat, keyboard.*.device);

        // Send modifiers to the client.
        c.wlr_seat_keyboard_notify_modifiers(keyboard.*.server.*.seat, &keyboard.*.device.*.unnamed_37.keyboard.*.modifiers);
    }

    fn handle_key(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is raised when a key is pressed or released.
        const keyboard = @fieldParentPtr(Keyboard, "listen_key", listener);
        const event = @ptrCast(
            *c.wlr_event_keyboard_key,
            @alignCast(@alignOf(*c.wlr_event_keyboard_key), data),
        );

        const server = keyboard.*.server;
        const seat = server.*.seat;
        const keyboard_device = keyboard.*.device.*.unnamed_37.keyboard;

        // Translate libinput keycode -> xkbcommon
        const keycode = event.*.keycode + 8;
        // Get a list of keysyms based on the keymap for this keyboard
        var syms: *c.xkb_keysym_t = undefined;
        const nsyms = c.xkb_state_key_get_syms(keyboard_device.*.xkb_state, keycode, &syms);

        var handled = false;
        const modifiers = c.wlr_keyboard_get_modifiers(keyboard_device);
        if (modifiers & @intCast(u32, c.WLR_MODIFIER_LOGO) != 0 and
            event.*.state == c.enum_wlr_key_state.WLR_KEY_PRESSED)
        {
            // If mod is held down and this button was _pressed_, we attempt to
            // process it as a compositor keybinding.
            var i: usize = 0;
            while (i < nsyms) {
                handled = keyboard.seat.server.handle_keybinding(syms[i]);
                if (handled) {
                    break;
                }
                i += 1;
            }
        }

        if (!handled) {
            // Otherwise, we pass it along to the client.
            c.wlr_seat_set_keyboard(seat, keyboard.*.device);
            c.wlr_seat_keyboard_notify_key(
                seat,
                event.*.time_msec,
                event.*.keycode,
                @intCast(u32, @enumToInt(event.*.state)),
            );
        }
    }
};
