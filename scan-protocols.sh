#!/bin/sh
wayland-scanner server-header protocol/xdg-shell.xml protocol/xdg-shell-protocol.h
wayland-scanner private-code protocol/xdg-shell.xml protocol/xdg-shell-protocol.c
