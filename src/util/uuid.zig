//! UUID utilities for testing and runtime.
//!
//! Provides UUID v4 generation functions using the cryptographically secure
//! UUID implementation from src/api/middleware/trace.zig.

const std = @import("std");
const trace = @import("../api/middleware/trace.zig");
const builtin = @import("builtin");

/// Raw 16-byte UUID v4 value (RFC 4122 compliant). Mirrors `std.uuid.Uuid`.
/// Used by TestHarness.newUuid() in tests/integration/helpers.zig and by
/// any consumer that wants a non-allocating, value-typed UUID suitable for
/// fixed-size struct fields and parameter arrays.
pub const Uuid = [16]u8;

/// Cryptographically secure fill for the raw 16-byte UUID v4 buffer. Same
/// platform dispatch as trace.zig's private fillRandom, but exposed here so
/// generateUuidV4BytesInto() can be inlined into a test-time code path that
/// does not need to allocate a 36-byte string.
fn fillRandomBytes(buf: []u8) void {
    switch (comptime builtin.os.tag) {
        .linux => _ = std.os.linux.getrandom(buf.ptr, buf.len, 0),
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .freebsd, .netbsd, .openbsd, .dragonfly => std.c.arc4random_buf(buf.ptr, buf.len),
        else => @compileError("fillRandomBytes: unsupported OS — add a platform branch"),
    }
}

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

/// Generate a raw 16-byte UUID v4 value (RFC 4122) directly into the provided
/// buffer. Sets the version-4 nibble on byte 6 and the RFC-4122 variant bits
/// on byte 8. No allocation. Buffer must be exactly 16 bytes (Uuid).
///
/// This is the non-string-allocating counterpart to generateUuidV4Into() —
/// used by TestHarness.newUuid() in tests/integration/helpers.zig so that
/// fixture-creation hot paths in MUST tests do not pay the 36-byte
/// allocation cost on every call.
pub fn generateUuidV4BytesInto(buf: *Uuid) void {
    fillRandomBytes(buf);
    // Set version 4 bits.
    buf[6] = (buf[6] & 0x0f) | 0x40;
    // Set variant bits (RFC 4122).
    buf[8] = (buf[8] & 0x3f) | 0x80;
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

test "generateUuidV4BytesInto: returns 16 bytes" {
    var buf: Uuid = undefined;
    generateUuidV4BytesInto(&buf);
    try testing.expectEqual(@as(usize, 16), buf.len);
}

test "generateUuidV4BytesInto: version nibble is 4" {
    var buf: Uuid = undefined;
    generateUuidV4BytesInto(&buf);
    try testing.expectEqual(@as(u8, (buf[6] & 0xf0) | 0x00), buf[6] & 0xf0);
    try testing.expectEqual(@as(u8, 0x40), buf[6] & 0xf0);
}

test "generateUuidV4BytesInto: variant bits are 10xx" {
    var buf: Uuid = undefined;
    generateUuidV4BytesInto(&buf);
    try testing.expectEqual(@as(u8, 0x80), buf[8] & 0xc0);
}

test "generateUuidV4BytesInto: produces distinct values" {
    var a: Uuid = undefined;
    var b: Uuid = undefined;
    generateUuidV4BytesInto(&a);
    generateUuidV4BytesInto(&b);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}
