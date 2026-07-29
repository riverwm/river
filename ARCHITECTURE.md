<!--
SPDX-FileCopyrightText: © 2026 The River Developers
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# Architecture

This is a high level overview of the structure of river's code base.

See also the [doc/internal](doc/internal) directory for in-depth documentation
of complex corners of the code base. If you are struggling to understand some
part of river's code and feel like it should have documentation in that
directory, feel free to open an issue.

## Window Management State Machine

At the heart of river lies the window management state machine specified in the
[river-window-management-v1] protocol and described in an [introductory blog
post] and [FOSDEM talk]. If you have not yet familiarized yourself with the
state machine, that should be your first step.

In river's code base the state machine is implemented in `WindowManager`. The
three core objects in the state machine are `Window`, `Output`, and `Seat`.
Each of these files contain `manageStart()`, `manageFinish()`, `renderStart()`,
and `renderFinish()` functions which progress the state machine, with the top
level WindowManager.zig calling into the subordinate objects.

## Input

The top level code handling input (e.g. from keyboard or pointer hardware) is
located in `InputManager`. `InputDevice` represents a single hardware or virtual
input source. Each `InputDevice` is assigned to exactly one `Seat`, which is
exposed to Wayland clients and the window management state machine.

## Output

The top level code handling output (i.e. compositing and displaying buffers on
your monitor) is located in `OutputManager`. Individual output devices are
represented by the `Output` type. For frame perfection, all changes to rendered
state are double-buffered and synchronized with the window management state
machine.

[river-window-management-v1]: https://isaacfreund.com/docs/wayland/river-window-management-v1/
[introductory blog post]: https://isaacfreund.com/blog/river-window-management/
[FOSDEM talk]: https://fosdem.org/2026/schedule/event/GR8BFE-separating_the_wayland_compositor_and_window_manager/
