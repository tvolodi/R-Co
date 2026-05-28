//! UUID utilities for testing and runtime.
//!
//! Provides UUID v4 generation functions using the cryptographically secure
//! UUID implementation from src/api/middleware/trace.zig.

const std = @import("std");
const trace = @import("../api/middleware/trace.zig");

/// Generate a UUID v4 string (36 bytes allocated by caller).
///
/// Returns an allocated slice owned by the caller.
/// Caller must allocator.free(result) when done.
pub fn newUuidV4(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [trace.UUID_V4_LEN]u8 = undefined;
    trace.generateUuidV4(&buf);
    return try allocator.dupe(u8, &buf);
}

/// Generate a UUID v4 string directly into the provided buffer.
/// buf must be exactly trace.UUID_V4_LEN bytes (36 bytes).
pub fn generateUuidV4Into(buf: *[trace.UUID_V4_LEN]u8) void {
    trace.generateUuidV4(buf);
}

/// Constant for UUID v4 string length (36 bytes: 8-4-4-4-12 with dashes).
pub const UUID_V4_LEN = trace.UUID_V4_LEN;

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "newUuidV4: returns 36-byte string" {
    const alloc = testing.allocator;
    const uuid = try newUuidV4(alloc);
    defer alloc.free(uuid);

    try testing.expectEqual(@as(usize, 36), uuid.len);
}

test "newUuidV4: dashes at correct positions" {
    const alloc = testing.allocator;
    const uuid = try newUuidV4(alloc);
    defer alloc.free(uuid);

    try testing.expectEqual('-', uuid[8]);
    try testing.expectEqual('-', uuid[13]);
    try testing.expectEqual('-', uuid[18]);
    try testing.expectEqual('-', uuid[23]);
}

test "newUuidV4: version nibble is 4" {
    const alloc = testing.allocator;
    const uuid = try newUuidV4(alloc);
    defer alloc.free(uuid);

    try testing.expectEqual('4', uuid[14]);
}

test "newUuidV4: variant is 8, 9, a, or b" {
    const alloc = testing.allocator;
    const uuid = try newUuidV4(alloc);
    defer alloc.free(uuid);

    const variant = uuid[19];
    const valid = variant == '8' or variant == '9' or variant == 'a' or variant == 'b';
    try testing.expect(valid);
}

test "newUuidV4: generates unique values" {
    const alloc = testing.allocator;
    const uuid1 = try newUuidV4(alloc);
    const uuid2 = try newUuidV4(alloc);
    defer {
        alloc.free(uuid1);
        alloc.free(uuid2);
    }

    try testing.expect(!std.mem.eql(u8, uuid1, uuid2));
}

test "generateUuidV4Into: fills buffer correctly" {
    var buf: [UUID_V4_LEN]u8 = undefined;
    generateUuidV4Into(&buf);

    try testing.expectEqual('-', buf[8]);
    try testing.expectEqual('-', buf[13]);
    try testing.expectEqual('-', buf[18]);
    try testing.expectEqual('-', buf[23]);
    try testing.expectEqual('4', buf[14]);
}
