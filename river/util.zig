// SPDX-FileCopyrightText: © 2022 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

/// The global general-purpose allocator used throughout river's code
pub const gpa = std.heap.c_allocator;
