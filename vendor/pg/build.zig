const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("pg", .{
        .root_source_file = b.path("pg.zig"),
    });
}
