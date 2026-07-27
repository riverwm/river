<!--
SPDX-FileCopyrightText: © 2026 The River Developers
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# Keyboards in river

Keyboard handling is currently one of the most complex parts of river. There is
a significant amount of inherent complexity involved, but there is certainly a
fair amount of accidental complexity as well.

This documentation aims to explain both how river's keyboard code works and why
things are structured how they are.

## Fundamentals

Raw keyboard events from the kernel are fed in to the libxkbcommon state machine
to handle keyboard layouts, modifiers, layers, and all the other keyboard options
that users expect.

The Wayland protocol exposes a single `wl_keyboard` object to clients per
`wl_seat`, which has a specific xkbcommon keymap and repeat info defined.
However, the user may have many physical keyboards plugged in to their computer
at the same time, each with a different keymap/repeat info configuration.

In order to handle multiple physical keyboards on the same `wl_seat`, the
compositor must maintain multiple separate libxkbcommon state machines in
parallel and switch which keyboard state is exposed to clients through the
single `wl_keyboard` interface based on which keyboard most recently had a
key pressed.

To allow modifiers (e.g. Shift or Alt) to work across different physical
keyboards, the compositor may use a single xkbcommon state machine for
multiple physical keyboards. This is only possible if the user has configured
the same keyboard layout and repeat info for all the physical keyboards in the
"keyboard group." This is very important for some hardware such as split
keyboards.

## River's extra needs

River requires more flexibility than other compositors here due to the
asynchronous nature of its window management protocol. In order to make certain
use-cases race free, river may require a roundtrip with the window manager
before processing further keyboard events.

For example, when the user presses key A and key B in rapid succession and the
window manager has configured a keybinding for key A, it may make a change to
window management state that changes how keyboard events are routed in response
to key A being pressed. This change could be switching focus to a different
window, defining new keybindings, disabling keybindings, etc. This requires
river to wait for the window manager to respond to the key A keybinding being
triggered before processing key B and potentially routing the key B event
incorrectly if the window manager does not respond fast enough.

## Wlroots API impedance mismatch

Wlroots combines the physical keyboard device and the xkbcommon state machine
in a single `wlr_keyboard` object. This is convenient for simple compositors
but is not well-suited to compositors with more complex requirements. It would
be far more flexible to have two separate objects:

1. A stateless object that exposes raw keyboard input events from the backend.
2. A stateful object that wraps an xkbcommon state machine and takes raw keyboard
input events as input.

(See wlroots issue [#4068](https://gitlab.freedesktop.org/wlroots/wlroots/-/work_items/4068))

As explained in the previous section, river needs to update the keyboard state
exposed to clients asynchronously as the window management state machine
advances. This means that river cannot directly expose the `wlr_keyboard`
objects implemented by wlroots to clients since their state is always updated
synchronously as the backend emits keyboard events. Luckily, wlroots allows
compositors to implement their own `wlr_keyboard` objects as well.

River treats the `wlr_keyboard` objects corresponding to physical keyboard
devices as statelEss event sources and never directly exposes them to clients
(See [Keyboard.zig](../../river/Keyboard.zig)). The client-facing, stateful
`wlr_keyboard` objects (aggregating raw events from one or more physical
keyboards) are implemented in river itself
(See [KeyboardGroup.zig](../../river/KeyboardGroup.zig)) and updated in sync with
river's window management state machine.

## Builtin Compositor Keybindings

River defines a small number of builtin keybindings that are always active and
cannot be overriden by the active window manager. Currently, the only builtin
keybindings are the standard VT switch keybindings, (e.g. Ctrl+Alt+F1). These
keybindings must always be active, even if the window manager freezes up due to
a bug. This means that the builtin keybindings must be handled before keyboard
events are added to the queue for asynchronous processing by the window
management state machine. To this end, river maintains a separate xkbcommon
state machine per `KeyboardGroup` that is used exclusively to handle builtin
keybindings.

## Keyboard Event Path in River

At a high level, the path a keyboard event takes through river's code looks like
this:

1. Backend emits a keyboard event
2. Check for builtin keybinding match and update builtin state
    - If matched, processing is complete.
3. Add keyboard event to input event queue.
4. Wait for the window management state machine to progress the queue.
5. Pop the keyboard event from the queue.
6. Check against window manager defined key bindings and route keyboard event
to the window manager or to the client with keyboard focus.
