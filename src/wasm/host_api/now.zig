//! Host API: now() -> string
//! Returns current timestamp in ISO 8601 format.

const std = @import("std");

/// Get current time as ISO 8601 string.
pub fn platform_now(allocator: std.mem.Allocator) ![]const u8 {
    // Placeholder: return current time stub
    var buf: [32]u8 = undefined;
    const timestamp = try std.fmt.bufPrint(&buf, "{d}", .{1000000});
    return try allocator.dupe(u8, timestamp);
}
