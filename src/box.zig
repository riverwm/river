const Self = @This();

const c = @import("c.zig");

x: i32,
y: i32,
width: u32,
height: u32,

pub fn toWlrBox(self: Self) c.wlr_box {
    return c.wlr_box{
        .x = @intCast(c_int, self.x),
        .y = @intCast(c_int, self.y),
        .width = @intCast(c_int, self.width),
        .height = @intCast(c_int, self.height),
    };
}
