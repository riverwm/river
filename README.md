<!--
SPDX-FileCopyrightText: © 2020 The River Developers
SPDX-License-Identifier: CC-BY-SA-4.0
-->

<div align="center">
  <img src="logo/logo_text_adaptive_color.svg" width="600em">
</div>

## Overview

River is a non-monolithic Wayland compositor. Unlike other Wayland compositors,
river does not combine the compositor and window manager into one program.
Instead, users can choose any window manager implementing the
[river-window-management-v1](protocol/river-window-management-v1.xml) protocol.

There is a [list of window managers](https://codeberg.org/river/wiki/src/branch/main/pages/wm-list.md)
implementing the [river-window-management-v1](protocol/river-window-management-v1.xml) protocol
on our [wiki](https://codeberg.org/river/wiki).

> *If you are looking for the old dynamic tiling version of river, see
[river-classic](https://codeberg.org/river/river-classic).*

## Links

- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Issue Tracker](https://codeberg.org/river/river/issues)
- IRC: [#river](https://web.libera.chat/?channels=#river) on irc.libera.chat
- [Zulip](https://river-compositor.zulipchat.com) (new)
- [Wiki](https://codeberg.org/river/wiki)

## Features

River defers all window management policy to a separate window manager
implementing the [river-window-management-v1](protocol/river-window-management-v1.xml)
protocol. This includes window position/size, pointer/keyboard bindings, focus
management, window decorations, desktop shell graphics, and more.

River itself provides frame perfect rendering, good performance, support for
many Wayland protocol extensions, robust Xwayland support, the ability to
hot-swap window managers, and more.

## Motivation

Why split the window manager to a separate process? I aim to:

- Significantly lower the barrier to entry for writing a Wayland window manager.
- Allow implementing Wayland window managers in high-level garbage collected
  languages without impacting compositor performance and latency.
- Allow hot-swapping between window managers without restarting the compositor
  and all Wayland programs.
- Promote diversity and experimentation in window manager design.

## Current Status

The first release supporting the
[river-window-management-v1](protocol/river-window-management-v1.xml) protocol
will be 0.4.0. The protocol is implemented on river's main branch and is already
robust/feature complete enough for me to use as my daily driver.  There are
however missing features that need to be implemented before the 0.4.0 release,
for example keyboard layout configuration.

Currently the only documentation for the
[river-window-management-v1](protocol/river-window-management-v1.xml) protocol
is the protocol specification itself. While this is all developers comfortable
with writing Wayland clients should need, I'd like to add some more
beginner-friendly documentation including a well-commented example window
manager before the 0.4.0 release.

I would also like to get more feedback on the
[river-window-management-v1](protocol/river-window-management-v1.xml) protocol
before the 0.4.0 release. If you are working on a window manager and have
questions/feedback I'd love to hear from you!

With regards to protocol stability, my goal is to never make a backwards
incompatible change and stay at `v1` forever. I've been iterating on this
protocol since April 2023 and am quite confident in the design and extensibility
of the current protocol.

If everything goes well with the 0.4.0 release, I expect the following
non-bugfix release to be river 1.0.0. After river 1.0.0, all backwards
incompatible changes will be strictly avoided.

## Building

Note: If you are packaging river for distribution, see [PACKAGING.md](PACKAGING.md).

To compile river first ensure that you have the following dependencies
installed. The "development" versions are required if applicable to your
distribution.

- [zig](https://ziglang.org/download/) 0.15
- wayland
- wayland-protocols
- [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) 0.19
- xkbcommon
- libevdev
- pixman
- pkg-config
- scdoc (optional, but required for man page generation)

Then run, for example:
```
zig build -Doptimize=ReleaseSafe --prefix ~/.local install
```
To enable Xwayland support pass the `-Dxwayland` option as well.
Run `zig build -h` to see a list of all options.

## Usage

River can either be run nested in an X11/Wayland session or directly
from a tty using KMS/DRM. Simply run the `river` command.

On startup river will run an executable file at `$XDG_CONFIG_HOME/river/init`
if such an executable exists. If `$XDG_CONFIG_HOME` is not set,
`~/.config/river/init` will be used instead.

Usually this executable is a shell script which starts the user's window manager
and any other long-running programs.

For complete documentation see the `river(1)` man page.

## Donate

If my work on river adds value to your life and you'd like to support me
financially you can find donation information [here](https://isaacfreund.com/donate/).

## Licensing

This project follows the [REUSE Specification](https://reuse.software/spec-3.3/),
all files have SPDX copyright and license information.

In overview:

- River's source code is released under the GPL-3.0-only license.
- River's Wayland protocols are released under the MIT license.
- River's logo and documentation are released under the CC-BY-SA-4.0 license.
