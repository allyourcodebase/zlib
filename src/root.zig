const std = @import("std");

pub const Deflate = @import("Deflate.zig");

comptime {
    std.testing.refAllDecls(Deflate);
}
