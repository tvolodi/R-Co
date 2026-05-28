//! Host API: call_service(svc_id: string, method: string, path: string, headers: table, body: string) -> table
//! Invokes an external service.

const std = @import("std");

/// Placeholder: actual implementation in Stage 10 with service catalog.
pub fn platform_call_service(
    svc_id: []const u8,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    _ = svc_id;
    _ = method;
    _ = path;
    _ = body;
    return try allocator.dupe(u8, "{}");
}
