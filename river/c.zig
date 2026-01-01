// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

pub const c = @cImport({
    @cDefine("_POSIX_C_SOURCE", "200809L");

    @cInclude("stdlib.h");
    @cInclude("unistd.h");

    @cInclude("linux/input-event-codes.h");
    @cInclude("libevdev/libevdev.h");

    @cInclude("libinput.h");
});
