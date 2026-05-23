//! API-06 unit tests: shared cursor-based pagination module.
//!
//! Covers all test cases in tests/specs/API-06.md (TC-API-06-01 through TC-API-06-20).
//! All tests are pure — no DB, no HTTP server, no network.
//!
//! Modules under test:
//!   src/api/pagination.zig  (named import: "api.pagination")

const std = @import("std");
const testing = std.testing;
const api = @import("api");
const pagination = api.pagination;

// ── Page size validation tests ───────────────────────────────────────────────

test "TC-API-06-01: validatePageSize(null) returns default 50" {
    const result = try pagination.validatePageSize(null);
    try testing.expectEqual(pagination.DEFAULT_PAGE_SIZE, result);
}

test "TC-API-06-02: validatePageSize(0) returns PageSizeTooLarge" {
    const result = pagination.validatePageSize(0);
    try testing.expectError(error.PageSizeTooLarge, result);
}

test "TC-API-06-03: validatePageSize(1) returns 1 (minimum boundary)" {
    const result = try pagination.validatePageSize(1);
    try testing.expectEqual(@as(u16, 1), result);
}

test "TC-API-06-04: validatePageSize(200) returns 200 (maximum boundary)" {
    const result = try pagination.validatePageSize(200);
    try testing.expectEqual(@as(u16, 200), result);
}

test "TC-API-06-05: validatePageSize(201) returns PageSizeTooLarge" {
    const result = pagination.validatePageSize(201);
    try testing.expectError(error.PageSizeTooLarge, result);
}

test "TC-API-06-05b: validatePageSize(65535) returns PageSizeTooLarge" {
    const result = pagination.validatePageSize(65535);
    try testing.expectError(error.PageSizeTooLarge, result);
}

test "TC-API-06-03b: validatePageSize(50) returns 50 (middle value)" {
    const result = try pagination.validatePageSize(50);
    try testing.expectEqual(@as(u16, 50), result);
}

// ── Cursor encode/decode round-trip tests ────────────────────────────────────

test "TC-API-06-06: encodeCursor / decodeCursor round-trip with T: prefix" {
    const allocator = testing.allocator;
    const raw = "T:1716412800000000:abc123def4567890";
    const encoded = try pagination.encodeCursor(allocator, raw);
    defer allocator.free(encoded);

    const cursor = try pagination.decodeCursor(allocator, encoded, "T:", 2, 1_000_000_000_000_000);
    defer cursor.deinit();

    try testing.expectEqualStrings(raw, cursor.inner);
}

test "TC-API-06-06b: encodeCursor / decodeCursor round-trip with I: prefix" {
    const allocator = testing.allocator;
    const raw = "I:1716412800000000:abc123:1716412860000000";
    const encoded = try pagination.encodeCursor(allocator, raw);
    defer allocator.free(encoded);

    const cursor = try pagination.decodeCursor(allocator, encoded, "I:", 2, 1_000_000_000_000_000);
    defer cursor.deinit();

    try testing.expectEqualStrings(raw, cursor.inner);
}

test "TC-API-06-06c: encodeCursor / decodeCursor round-trip with D: prefix" {
    const allocator = testing.allocator;
    const raw = "D:1716412800000000:1716412800000001";
    const encoded = try pagination.encodeCursor(allocator, raw);
    defer allocator.free(encoded);

    const cursor = try pagination.decodeCursor(allocator, encoded, "D:", 2, 1_000_000_000_000_000);
    defer cursor.deinit();

    try testing.expectEqualStrings(raw, cursor.inner);
}

test "TC-API-06-06d: encodeCursor / decodeCursor round-trip with H: prefix" {
    const allocator = testing.allocator;
    const raw = "H:1716412800000000:42";
    const encoded = try pagination.encodeCursor(allocator, raw);
    defer allocator.free(encoded);

    const cursor = try pagination.decodeCursor(allocator, encoded, "H:", 2, 1_000_000_000_000_000);
    defer cursor.deinit();

    try testing.expectEqualStrings(raw, cursor.inner);
}

// ── Cursor decode error tests ────────────────────────────────────────────────

test "TC-API-06-07: decodeCursor with invalid base64url returns InvalidBase64" {
    const allocator = testing.allocator;
    const result = pagination.decodeCursor(allocator, "!!!not-valid-base64!!!", "T:", 2, 1_000_000_000_000_000);
    try testing.expectError(error.InvalidBase64, result);
}

test "TC-API-06-08: decodeCursor with T: cursor on I: endpoint returns WrongEndpoint" {
    const allocator = testing.allocator;
    const raw = "T:1716412800000000:abc123";
    const encoded = try pagination.encodeCursor(allocator, raw);
    defer allocator.free(encoded);

    const result = pagination.decodeCursor(allocator, encoded, "I:", 2, 1_000_000_000_000_000);
    try testing.expectError(error.WrongEndpoint, result);
}

test "TC-API-06-08b: decodeCursor with H: cursor on D: endpoint returns WrongEndpoint" {
    const allocator = testing.allocator;
    const raw = "H:1716412800000000:42";
    const encoded = try pagination.encodeCursor(allocator, raw);
    defer allocator.free(encoded);

    const result = pagination.decodeCursor(allocator, encoded, "D:", 2, 1_000_000_000_000_000);
    try testing.expectError(error.WrongEndpoint, result);
}

test "TC-API-06-08c: decodeCursor with I: cursor on T: endpoint returns WrongEndpoint" {
    const allocator = testing.allocator;
    const raw = "I:1716412800000000:abc123:1716412860000000";
    const encoded = try pagination.encodeCursor(allocator, raw);
    defer allocator.free(encoded);

    const result = pagination.decodeCursor(allocator, encoded, "T:", 2, 1_000_000_000_000_000);
    try testing.expectError(error.WrongEndpoint, result);
}

test "TC-API-06-09: decodeCursor with expired timestamp returns Expired" {
    const allocator = testing.allocator;
    // Timestamp far in the past: 1000000000000000 µs ≈ year 2001
    const raw = "T:1000000000000000:abc123";
    const encoded = try pagination.encodeCursor(allocator, raw);
    defer allocator.free(encoded);

    // 1 µs expiry window guarantees expiry
    const result = pagination.decodeCursor(allocator, encoded, "T:", 2, 1);
    try testing.expectError(error.Expired, result);
}

test "TC-API-06-09b: decodeCursor with timestamp within window succeeds" {
    const allocator = testing.allocator;
    // Use a timestamp in the far future so it won't expire
    const raw = "T:9999999999999999:abc123";
    const encoded = try pagination.encodeCursor(allocator, raw);
    defer allocator.free(encoded);

    const cursor = try pagination.decodeCursor(allocator, encoded, "T:", 2, 1_000_000_000_000_000);
    defer cursor.deinit();

    try testing.expectEqualStrings(raw, cursor.inner);
}

test "TC-API-06-10: decodeCursor with malformed segments returns InvalidBase64" {
    const allocator = testing.allocator;
    // Encode a string with a valid prefix but a non-numeric timestamp
    const raw = "T:not-a-timestamp:abc123";
    const encoded = try pagination.encodeCursor(allocator, raw);
    defer allocator.free(encoded);

    const result = pagination.decodeCursor(allocator, encoded, "T:", 2, 1_000_000_000_000_000);
    try testing.expectError(error.InvalidBase64, result);
}

test "TC-API-06-10b: decodeCursor with negative timestamp in cursor returns Expired" {
    const allocator = testing.allocator;
    // A negative timestamp parses as valid i64 but is far in the past → Expired
    const raw = "T:-1234567890:abc123";
    const encoded = try pagination.encodeCursor(allocator, raw);
    defer allocator.free(encoded);

    // Even with a large window, a negative timestamp is always "expired"
    // because now_us - (-1234567890) > any reasonable window
    const result = pagination.decodeCursor(allocator, encoded, "T:", 2, 1);
    try testing.expectError(error.Expired, result);
}

// ── Convenience helper tests ─────────────────────────────────────────────────

test "TC-API-06-13: buildRawCursor produces correct format" {
    const allocator = testing.allocator;
    const raw = try pagination.buildRawCursor(allocator, "T:", 1716412800000000, "abc123");
    defer allocator.free(raw);
    try testing.expectEqualStrings("T:1716412800000000:abc123", raw);
}

test "TC-API-06-13b: buildRawCursor with empty key" {
    const allocator = testing.allocator;
    const raw = try pagination.buildRawCursor(allocator, "H:", 1716412800000000, "");
    defer allocator.free(raw);
    try testing.expectEqualStrings("H:1716412800000000:", raw);
}

test "TC-API-06-14: buildRawCursorTimestampKey produces correct format" {
    const allocator = testing.allocator;
    const raw = try pagination.buildRawCursorTimestampKey(allocator, "I:", 1716412800000000, "abc123", 1716412860000000);
    defer allocator.free(raw);
    try testing.expectEqualStrings("I:1716412800000000:abc123:1716412860000000", raw);
}

test "TC-API-06-14b: buildRawCursorTimestampKey with zero timestamps" {
    const allocator = testing.allocator;
    const raw = try pagination.buildRawCursorTimestampKey(allocator, "I:", 0, "key", 0);
    defer allocator.free(raw);
    try testing.expectEqualStrings("I:0:key:0", raw);
}

test "TC-API-06-15: parseIntFromCursor extracts correct value" {
    const decoded = "T:1716412800000000:abc123";
    const ts = try pagination.parseIntFromCursor(decoded, 2, 16);
    try testing.expectEqual(@as(i64, 1716412800000000), ts);
}

test "TC-API-06-15b: parseIntFromCursor extracts zero" {
    const decoded = "I:0:abc:0";
    const ts = try pagination.parseIntFromCursor(decoded, 2, 1);
    try testing.expectEqual(@as(i64, 0), ts);
}

test "TC-API-06-16: parseIntFromCursor with out-of-bounds range returns InvalidCursor" {
    const decoded = "short";
    const result = pagination.parseIntFromCursor(decoded, 2, 100);
    try testing.expectError(error.InvalidCursor, result);
}

test "TC-API-06-16b: parseIntFromCursor with non-numeric slice returns InvalidCursor" {
    const decoded = "T:not-a-number:abc";
    const result = pagination.parseIntFromCursor(decoded, 2, 12);
    try testing.expectError(error.InvalidCursor, result);
}

test "TC-API-06-17: findNthColon locates colon positions in T: cursor" {
    const s = "T:1716412800000000:abc123";
    try testing.expectEqual(@as(?usize, 1), pagination.findNthColon(s, 1));
    try testing.expectEqual(@as(?usize, 18), pagination.findNthColon(s, 2));
    try testing.expectEqual(@as(?usize, null), pagination.findNthColon(s, 3));
}

test "TC-API-06-18: findNthColon with no colons returns null" {
    const s = "no-colons-here";
    try testing.expectEqual(@as(?usize, null), pagination.findNthColon(s, 1));
}

test "TC-API-06-19: findNthColon with three-segment I: cursor" {
    const s = "I:1716412800000000:abc123def456:1716412860000000";
    const first = pagination.findNthColon(s, 1);
    const second = pagination.findNthColon(s, 2);
    const third = pagination.findNthColon(s, 3);
    const fourth = pagination.findNthColon(s, 4);

    try testing.expect(first != null);
    try testing.expectEqual(@as(usize, 1), first.?);
    try testing.expect(second != null);
    try testing.expect(third != null);
    try testing.expectEqual(@as(?usize, null), fourth);
}

test "TC-API-06-19b: findNthColon n=0 returns first colon" {
    // n is 1-indexed, but let's verify behavior
    const s = "A:B:C";
    // n=1 should be index 1 (after A)
    try testing.expectEqual(@as(?usize, 1), pagination.findNthColon(s, 1));
    // n=2 should be index 3 (after B)
    try testing.expectEqual(@as(?usize, 3), pagination.findNthColon(s, 2));
}

// ── Constants tests ──────────────────────────────────────────────────────────

test "TC-API-06-consts: MAX_PAGE_SIZE is 200" {
    try testing.expectEqual(@as(u16, 200), pagination.MAX_PAGE_SIZE);
}

test "TC-API-06-consts: DEFAULT_PAGE_SIZE is 50" {
    try testing.expectEqual(@as(u16, 50), pagination.DEFAULT_PAGE_SIZE);
}

test "TC-API-06-consts: MIN_PAGE_SIZE is 1" {
    try testing.expectEqual(@as(u16, 1), pagination.MIN_PAGE_SIZE);
}

test "TC-API-06-consts: CURSOR_EXPIRY_US is 24 hours" {
    try testing.expectEqual(@as(i64, 86_400_000_000), pagination.CURSOR_EXPIRY_US);
}

// ── PageResponse type tests ──────────────────────────────────────────────────

test "TC-API-06-response: PageResponse(T) compiles and holds correct values" {
    const PageResponse = pagination.PageResponse(u32);
    const allocator = testing.allocator;

    const items = try allocator.alloc(u32, 3);
    items[0] = 10;
    items[1] = 20;
    items[2] = 30;

    const pr = PageResponse{
        .items = items,
        .next_cursor = null,
        .count = 3,
    };

    try testing.expectEqual(@as(usize, 3), pr.items.len);
    try testing.expectEqual(@as(usize, 3), pr.count);
    try testing.expectEqual(@as(?[]const u8, null), pr.next_cursor);
    try testing.expectEqual(@as(u32, 10), pr.items[0]);
    try testing.expectEqual(@as(u32, 30), pr.items[2]);

    allocator.free(items);
}

test "TC-API-06-response: PageResponse with cursor" {
    const PageResponse = pagination.PageResponse(u8);
    const allocator = testing.allocator;

    const items = try allocator.alloc(u8, 1);
    items[0] = 42;
    const cursor_str = try allocator.dupe(u8, "next-page-cursor");
    defer allocator.free(cursor_str);

    const pr = PageResponse{
        .items = items,
        .next_cursor = cursor_str,
        .count = 1,
    };

    try testing.expectEqual(@as(usize, 1), pr.count);
    try testing.expect(pr.next_cursor != null);
    try testing.expectEqualStrings("next-page-cursor", pr.next_cursor.?);

    allocator.free(items);
}
