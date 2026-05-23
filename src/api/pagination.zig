//! Shared cursor-based pagination module (API-06).
//!
//! Centralises cursor encoding/decoding, prefix validation, expiry checking,
//! page size validation, and a standardised PageResponse(T) struct.
//! All list endpoints SHALL delegate pagination concerns to this module,
//! eliminating duplicated encode/decode/expiry code.
//!
//! Wire in each route handler:
//!   const pagination = @import("../pagination.zig");

const std = @import("std");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Maximum allowed page size for any list endpoint.
pub const MAX_PAGE_SIZE: u16 = 200;

/// Default page size when not specified by the caller.
pub const DEFAULT_PAGE_SIZE: u16 = 50;

/// Minimum allowed page size.
pub const MIN_PAGE_SIZE: u16 = 1;

/// Standard expiry window: 24 hours in microseconds.
pub const CURSOR_EXPIRY_US: i64 = 86_400_000_000;

// ---------------------------------------------------------------------------
// Error sets
// ---------------------------------------------------------------------------

pub const PageSizeError = error{
    PageSizeTooLarge,
};

pub const CursorError = error{
    /// The base64url string is malformed.
    InvalidBase64,
    /// The cursor prefix does not match this endpoint.
    WrongEndpoint,
    /// The cursor has expired (> expiry_window_us old).
    Expired,
    /// Out of memory during decode.
    OutOfMemory,
};

pub const CursorParseError = error{
    /// The cursor string does not contain the expected numeric value.
    InvalidCursor,
};

// ---------------------------------------------------------------------------
// Core types
// ---------------------------------------------------------------------------

/// A decoded, validated pagination cursor.
///
/// After successful decode+expiry check, handlers use the opaque `inner` value
/// directly as the store-layer continuation parameter.
pub const Cursor = struct {
    /// The raw decoded inner value (format depends on endpoint).
    /// Callers do not interpret this — they pass it to their store/list function.
    inner: []const u8,
    /// The allocator that owns `inner`; caller must free via `cursor.deinit()`.
    allocator: std.mem.Allocator,

    /// Release the decoded inner buffer.
    pub fn deinit(self: *const Cursor) void {
        self.allocator.free(self.inner);
    }
};

/// Standard page response envelope for all paginated list endpoints.
///
/// Serialised as:
///   { "items": [...], "next_cursor": "<base64url>" | null, "count": N }
pub fn PageResponse(comptime T: type) type {
    return struct {
        /// Items on this page. May be empty (len=0) for an empty result set.
        items: []T,
        /// Opaque cursor for the next page; null if this is the last page.
        next_cursor: ?[]const u8,
        /// Number of items on this page.
        count: usize,
    };
}

// ---------------------------------------------------------------------------
// Page size validation
// ---------------------------------------------------------------------------

/// Validate a raw page_size parameter.
///
/// Returns the validated u16 value, or an error.
///   - null     → returns DEFAULT_PAGE_SIZE
///   - 0        → error.PageSizeTooLarge (HTTP 422 per API-06 requirement)
///   - 1..200   → returns the value
///   - >200     → error.PageSizeTooLarge
pub fn validatePageSize(raw: ?u16) PageSizeError!u16 {
    const v = raw orelse return DEFAULT_PAGE_SIZE;
    if (v == 0) return error.PageSizeTooLarge;
    if (v > MAX_PAGE_SIZE) return error.PageSizeTooLarge;
    return v;
}

// ---------------------------------------------------------------------------
// Cursor encoding
// ---------------------------------------------------------------------------

/// Encode a raw cursor payload into an opaque base64url (no-padding) string.
///
/// `raw` is the endpoint-specific cursor payload, e.g. "T:1716412800000000:abc123...def".
/// Caller owns the returned string — free with `allocator.free(encoded)`.
pub fn encodeCursor(allocator: std.mem.Allocator, raw: []const u8) error{OutOfMemory}![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(raw.len);
    const buf = try allocator.alloc(u8, out_len);
    _ = encoder.encode(buf, raw);
    return buf;
}

// ---------------------------------------------------------------------------
// Cursor decoding with prefix and expiry validation
// ---------------------------------------------------------------------------

/// Decode and validate a cursor string.
///
/// Performs three checks:
///   1. Base64url decode — invalid encoding → error.InvalidBase64.
///   2. Prefix match — `prefix` must be a non-null literal like "T:", "H:", "I:", "D:".
///      If the decoded value does not start with `prefix`, returns error.WrongEndpoint.
///   3. Expiry check — the decoded cursor must contain an embedded creation timestamp
///      at the position indicated by `expiry_ts_offset`.  The offset is the byte index
///      from the beginning of the decoded string at which the decimal-encoded
///      microsecond timestamp begins.  Cursors older than `expiry_window_us`
///      (default 24h) return error.Expired.
///
/// Returns a Cursor with the decoded inner value; caller owns the inner buffer.
pub fn decodeCursor(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    prefix: []const u8,
    expiry_ts_offset: usize,
    expiry_window_us: i64,
) CursorError!Cursor {
    // 1. Base64url decode
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    decoder.decode(decoded, encoded) catch return error.InvalidBase64;

    // 2. Prefix match
    if (decoded.len < prefix.len or !std.mem.startsWith(u8, decoded, prefix)) {
        return error.WrongEndpoint;
    }

    // 3. Expiry check — extract timestamp from decoded[expiry_ts_offset..]
    if (expiry_ts_offset >= decoded.len) {
        return error.InvalidBase64;
    }

    const ts_slice = decoded[expiry_ts_offset..];
    const ts_end = std.mem.indexOfScalar(u8, ts_slice, ':') orelse ts_slice.len;
    if (ts_end == 0) {
        return error.InvalidBase64;
    }
    const ts = std.fmt.parseInt(i64, ts_slice[0..ts_end], 10) catch return error.InvalidBase64;

    const now_us = currentMicrosecondTimestamp();
    if (now_us - ts > expiry_window_us) {
        return error.Expired;
    }

    return Cursor{
        .inner = decoded,
        .allocator = allocator,
    };
}

// ---------------------------------------------------------------------------
// Convenience helpers
// ---------------------------------------------------------------------------

/// Build a raw cursor payload for endpoints using the standard `PREFIX:ts_us:key` format.
///
/// `prefix` — literal such as "T:", "I:", "H:", "D:".
/// `timestamp_us` — current wall-clock time in microseconds (for expiry checking).
/// `key` — the sort-key value for this cursor position (e.g. task_id_hex, sequence_number).
///
/// Returns an allocator-owned string like "T:1716412800000000:abc123".
pub fn buildRawCursor(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    timestamp_us: i64,
    key: []const u8,
) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{d}:{s}", .{ prefix, timestamp_us, key });
}

/// Build a raw cursor payload for endpoints whose sort key is also a timestamp.
///
/// `prefix` — literal.
/// `sort_timestamp_us` — the sort position (e.g. started_at of last item).
/// `key` — additional discriminator after the sort timestamp (e.g. instance_id_hex).
/// `cursor_created_at_us` — current time for expiry checking.
///
/// Returns: "I:1716412800000000:abc123:1716412860000000"
pub fn buildRawCursorTimestampKey(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    sort_timestamp_us: i64,
    key: []const u8,
    cursor_created_at_us: i64,
) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}{d}:{s}:{d}",
        .{ prefix, sort_timestamp_us, key, cursor_created_at_us },
    );
}

/// Extract a decimal i64 from `decoded` at byte range [offset..offset+len).
/// The range must contain only ASCII decimal digits (and optionally a leading '-'
/// if negative timestamps are possible, though they should not be).
pub fn parseIntFromCursor(
    decoded: []const u8,
    offset: usize,
    len: usize,
) CursorParseError!i64 {
    if (offset + len > decoded.len) return error.InvalidCursor;
    const slice = decoded[offset .. offset + len];
    return std.fmt.parseInt(i64, slice, 10) catch error.InvalidCursor;
}

/// Locate the n-th colon (':') separator in a slice (1-indexed).
/// Returns the byte index of that colon, or null if fewer than `n` colons exist.
pub fn findNthColon(slice: []const u8, n: usize) ?usize {
    var count: usize = 0;
    for (slice, 0..) |c, idx| {
        if (c == ':') {
            count += 1;
            if (count == n) return idx;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Internal: wall-clock time (permitted in the API handler layer only)
// ---------------------------------------------------------------------------

/// Return the current wall-clock time as UTC microseconds since Unix epoch.
///
/// Uses OS-level APIs; permitted in src/api/ only — never called from
/// src/engine/transition.zig or any pure-function module.
fn currentMicrosecondTimestamp() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return @divTrunc(unix_100ns, 10);
    } else {
        const posix = std.posix;
        var ts: posix.timespec = undefined;
        _ = posix.system.clock_gettime(.REALTIME, &ts);
        const sec_us: i64 = ts.sec * 1_000_000;
        const nsec_us: i64 = @divTrunc(ts.nsec, 1000);
        return sec_us + nsec_us;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "validatePageSize: null returns default" {
    const result = try validatePageSize(null);
    try std.testing.expectEqual(DEFAULT_PAGE_SIZE, result);
}

test "validatePageSize: 0 returns error" {
    const result = validatePageSize(0);
    try std.testing.expectError(error.PageSizeTooLarge, result);
}

test "validatePageSize: valid value" {
    const result = try validatePageSize(100);
    try std.testing.expectEqual(@as(u16, 100), result);
}

test "validatePageSize: too large" {
    const result = validatePageSize(201);
    try std.testing.expectError(error.PageSizeTooLarge, result);
}

test "validatePageSize: at boundary" {
    const result = try validatePageSize(200);
    try std.testing.expectEqual(@as(u16, 200), result);
}

test "encodeCursor round-trip" {
    const allocator = std.testing.allocator;
    const raw = "T:1716412800000000:abc123";
    const encoded = try encodeCursor(allocator, raw);
    defer allocator.free(encoded);

    // Decode back
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try decoder.decode(decoded, encoded);

    try std.testing.expectEqualStrings(raw, decoded);
}

test "decodeCursor: valid T: cursor" {
    const allocator = std.testing.allocator;
    const raw = "T:1716412800000000:abc123";
    const encoded = try encodeCursor(allocator, raw);
    defer allocator.free(encoded);

    // Use a very large expiry window so it doesn't expire during test
    const cursor = try decodeCursor(allocator, encoded, "T:", 2, 1_000_000_000_000_000);
    defer cursor.deinit();

    try std.testing.expectEqualStrings(raw, cursor.inner);
}

test "decodeCursor: wrong prefix returns WrongEndpoint" {
    const allocator = std.testing.allocator;
    const raw = "T:1716412800000000:abc123";
    const encoded = try encodeCursor(allocator, raw);
    defer allocator.free(encoded);

    const result = decodeCursor(allocator, encoded, "H:", 2, 1_000_000_000_000_000);
    try std.testing.expectError(error.WrongEndpoint, result);
}

test "decodeCursor: invalid base64 returns InvalidBase64" {
    const allocator = std.testing.allocator;
    const result = decodeCursor(allocator, "!!!not-valid-base64!!!", "T:", 2, 1_000_000_000_000_000);
    try std.testing.expectError(error.InvalidBase64, result);
}

test "decodeCursor: expired cursor returns Expired" {
    const allocator = std.testing.allocator;
    // Create a cursor with a timestamp far in the past
    const raw = "T:1000000000000000:abc123";
    const encoded = try encodeCursor(allocator, raw);
    defer allocator.free(encoded);

    // Use a 1 microsecond expiry window — this will definitely be expired
    const result = decodeCursor(allocator, encoded, "T:", 2, 1);
    try std.testing.expectError(error.Expired, result);
}

test "buildRawCursor: correct format" {
    const allocator = std.testing.allocator;
    const raw = try buildRawCursor(allocator, "T:", 1716412800000000, "abc123");
    defer allocator.free(raw);
    try std.testing.expectEqualStrings("T:1716412800000000:abc123", raw);
}

test "buildRawCursorTimestampKey: correct format" {
    const allocator = std.testing.allocator;
    const raw = try buildRawCursorTimestampKey(allocator, "I:", 1716412800000000, "abc123", 1716412860000000);
    defer allocator.free(raw);
    try std.testing.expectEqualStrings("I:1716412800000000:abc123:1716412860000000", raw);
}

test "parseIntFromCursor: valid extraction" {
    const decoded = "T:1716412800000000:abc123";
    const ts = try parseIntFromCursor(decoded, 2, 16);
    try std.testing.expectEqual(@as(i64, 1716412800000000), ts);
}

test "parseIntFromCursor: out of bounds" {
    const decoded = "short";
    const result = parseIntFromCursor(decoded, 2, 100);
    try std.testing.expectError(error.InvalidCursor, result);
}

test "findNthColon: basic" {
    const s = "T:1716412800000000:abc123";
    try std.testing.expectEqual(@as(?usize, 1), findNthColon(s, 1));
    try std.testing.expectEqual(@as(?usize, 18), findNthColon(s, 2));
    try std.testing.expectEqual(@as(?usize, null), findNthColon(s, 3));
}

test "findNthColon: no colons" {
    const s = "no-colons-here";
    try std.testing.expectEqual(@as(?usize, null), findNthColon(s, 1));
}

test "findNthColon: three segment I: cursor" {
    const s = "I:1716412800000000:abc123def456:1716412860000000";
    try std.testing.expectEqual(@as(?usize, 1), findNthColon(s, 1));
    try std.testing.expectEqual(@as(?usize, 18), findNthColon(s, 2));
    // Third colon position may vary with instance_id_hex length
    const third = findNthColon(s, 3);
    try std.testing.expect(third != null);
}
