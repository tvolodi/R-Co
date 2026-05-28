//! Host API: read_variable(key: string) -> string
//! Reads a variable from instance state.

const std = @import("std");

/// Placeholder: actual implementation in Stage 10 with service catalog.
pub fn platform_read_variable(
    _: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    // For now, return a placeholder
    return try allocator.dupe(u8, "{}");
}
