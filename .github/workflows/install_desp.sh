#!/bin/sh

xbps-install -S
xbps-install -uy xbps
xbps-install -uy MesaLib-devel libseat-devel eudev-libudev-devel libdrm-devel \
  libinput-devel libxkbcommon-devel pixman-devel wayland-devel wayland-protocols \
  xcb-util-errors-devel xcb-util-wm-devel xcb-util-renderutil-devel libxcb-devel \
  xcb-util-cursor-devel xcb-util-devel xcb-util-image-devel xcb-util-keysyms-devel \
  xcb-util-xrm-devel xorg-server-xwayland pkg-config meson git gcc \
  zig pkgconf scdoc