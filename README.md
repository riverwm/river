# river

river is a dynamic wayland compositor that takes inspiration from
[dwm](https://dwm.suckless.org) and
[bspwm](https://github.com/baskerville/bspwm).

*Note: river is currently early in development and may lack some
features. If there are specific features blocking you from using river,
don't hesitate to
[open an issue](https://github.com/ifreund/river/issues/new)*

## Design goals

- Simplicity and minimalism, river should not overstep the bounds of a
window manger.
- Dynamic window management based on a stack of views and tags like dwm.
- Scriptable configuration and control through a separate binary,
`riverctl`, like bspwm. This works using the custom
[river-control](protocol/river-control-unstable-v1.xml) protocol.

## Building

To compile river first ensure that you have the following dependencies
installed:

- [zig](https://github.com/ziglang/zig) 0.6.0
- wayland
- wayland-protocols
- [wlroots](https://github.com/swaywm/wlroots) 0.10.1
- xkbcommon
- pixman
- pkg-config

Then simply use `zig build` to build and `zig build run` to run. This will also
build `riverctl` which can be found at `zig-cache/bin/riverctl`. To enable
experimental Xwayland support use `-Dxwayland=true`.

River can either be run nested in an X11/wayland session or directly
from a tty using KMS/DRM.

Keybinds are similar to the defaults of dwm, but using the "logo key"
instead of alt. Check out the comments in [config.zig](src/config.zig) for
a complete list of bindings. Note that the terminal emulator is currently
hardcoded to [alacritty](https://github.com/alacritty/alacritty) but
may be changed by editing [config.zig](src/config.zig) and recompiling.

## Development

Check out the [roadmap](https://github.com/ifreund/river/issues/1)
if you'd like to see what has been done and what is left to do.

If you are interested in the development of river, please join our
matrix channel: [#river:matrix.org](https://matrix.to/#/#river:matrix.org).
You should also read [CONTRIBUTING.md](CONTRIBUTING.md) if you intend
to submit patches.

I can often be found in the `#sway-devel` IRC channel with the
nick `ifreund` on irc.freenode.net as well, or reached by email at
[ifreund@ifreund.xyz](mailto:ifreund@ifreund.xyz).

## Licensing 

river is released under the GNU General Public License version 3, or (at your
option) any later version.

The protocols in the `protocol` directory are released under various licenses by
various parties. You should refer to the copyright block of each protocol for
the licensing information. The protocols prefixed with `river` and developed by
this project are released under the ISC license (as stated in their copyright
blocks).
