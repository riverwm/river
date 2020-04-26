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
- Scriptable configuration and control through a socket and separate
binary, `riverctl`, like bspwm.

## Packaging status

River is available from the
[AUR](https://aur.archlinux.org/packages/river-git/). Note that river
is still pre-0.1.0 and may lack features you deem necessary.

## Building

To compile river first ensure that you have the following dependencies
installed:

- [zig](https://github.com/ziglang/zig) 0.6.0
- wayland
- wayland-protocols
- [wlroots](https://github.com/swaywm/wlroots) 0.10.1
- xkbcommon

Then simply use `zig build` to build and `zig build run` to run.

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
