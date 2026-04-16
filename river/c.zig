// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

pub const c = @cImport({
    @cInclude("linux/input-event-codes.h");
    @cInclude("libevdev/libevdev.h");
    @cInclude("libinput.h");
});
