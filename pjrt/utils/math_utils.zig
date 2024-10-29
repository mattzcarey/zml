const std = @import("std");

pub fn nanoToPico(comptime T: type, n: T) !T {
    return std.math.mul(T, n, 1000);
}

pub fn picoToMicro(p: anytype) f64 {
    return @as(f64, @floatFromInt(p)) / 1E6;
}
