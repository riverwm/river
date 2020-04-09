#!/bin/sh
wayland-scanner server-header protocol/xdg-shell.xml protocol/xdg-shell-protocol.h
wayland-scanner private-code protocol/xdg-shell.xml protocol/xdg-shell-protocol.c

wayland-scanner server-header protocol/wlr-layer-shell-unstable-v1.xml protocol/wlr-layer-shell-unstable-v1-protocol.h
wayland-scanner private-code protocol/wlr-layer-shell-unstable-v1.xml protocol/wlr-layer-shell-unstable-v1-protocol.c
