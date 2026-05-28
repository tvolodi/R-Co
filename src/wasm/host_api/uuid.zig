//! Host API: uuid() -> string
//! Generates a UUID v4.

const std = @import("std");

/// Generate a UUID v4 string.
pub fn platform_uuid(allocator: std.mem.Allocator) ![]const u8 {
    // Simple placeholder UUID (will use real UUID in Stage 10)
    var buf: [36]u8 = undefined;

    const uuid_str = try std.fmt.bufPrint(
        &buf,
        "00000000-0000-0000-0000-000000000000",
        .{},
    );

    return try allocator.dupe(u8, uuid_str);
}
