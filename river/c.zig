// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

pub usingnamespace @cImport({
    @cDefine("_POSIX_C_SOURCE", "200809L");

    @cInclude("stdlib.h");
    @cInclude("unistd.h");

    @cInclude("linux/input-event-codes.h");
    @cInclude("libevdev/libevdev.h");

    @cInclude("libinput.h");

    @cInclude("xcb/xcb.h");
});
