pub fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

pub fn min(comptime T: type, a: T, b: T) T {
    return if (a < b) a else b;
}
