//! Unit tests for API-05 — History endpoint handler layer.
//!
//! These tests exercise the pure input-validation early-exit paths in the
//! handleHistory handler function.  All paths that return before any
//! event_store.Store method is called can be tested without a database
//! connection.  Store-touching paths are covered by integration tests in
//! tests/integration/.
//!
//! Strategy: pass an `undefined` Store pointer to handlers whose failing
//! branch is reached before the first store field access.  This is safe only
//! when the handler is guaranteed to return on a validation error before
//! accessing the store — confirmed by reading handleHistory's early-exit
//! branches in src/api/routes/instances.zig.
//!
//! Cursor encode/decode and ISO 8601 parsing are private functions in
//! instances.zig; they are tested INDIRECTLY through handleHistory by passing
//! parameters that exercise each code path.
//!
//! Requirement traceability:
//!   API-05 → TC-API-05-06  (from > to → HTTP 422)
//!            TC-API-05-10  (invalid cursor → HTTP 422)
//!            TC-API-05-11  (expired cursor → HTTP 410)
//!            TC-API-05-12  (page_size validation)
//!            TC-API-05-14  (ISO 8601 timestamp parsing)
//!            TC-API-05-15  (invalid instance_id UUID → HTTP 422)
//!            TC-API-05-17  (cross-endpoint cursor → HTTP 422)
//!            TC-API-05-18  (invalid from timestamp → HTTP 422)
//!            TC-API-05-19  (invalid to timestamp → HTTP 422)
//!
//! Run with: zig build test

const std = @import("std");
const testing = std.testing;

// src/main.zig is wired as the named "bpm" module in build.zig.
// It publishes instance_routes (src/api/routes/instances.zig).
const bpm = @import("bpm");
const instances = bpm.instance_routes;
const EventStore = bpm.event_store.Store;

// ---------------------------------------------------------------------------
// Helper: encode a byte slice as base64url (no padding)
// ---------------------------------------------------------------------------
fn base64urlEncode(alloc: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(data.len);
    const buf = try alloc.alloc(u8, out_len);
    _ = encoder.encode(buf, data);
    return buf;
}

// ---------------------------------------------------------------------------
// TC-API-05-15: handleHistory — invalid instance_id → HTTP 422
// ---------------------------------------------------------------------------

test "TC-API-05-15: handleHistory with non-UUID instance_id returns HTTP 422 INVALID_INSTANCE_ID" {
    const alloc = testing.allocator;

    // The handler validates the path param before calling the store.
    // Passing undefined is safe because the store is never accessed.
    var dummy_store: EventStore = undefined;
    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        "not-a-uuid",
        instances.HistoryParams{
            .event_type = null,
            .from = null,
            .to = null,
            .cursor = null,
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_INSTANCE_ID"));
}

test "TC-API-05-15b: handleHistory with short instance_id string returns HTTP 422 INVALID_INSTANCE_ID" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        "12345678",
        instances.HistoryParams{
            .event_type = null,
            .from = null,
            .to = null,
            .cursor = null,
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_INSTANCE_ID"));
}

test "TC-API-05-15c: handleHistory with empty instance_id string returns HTTP 422" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        "",
        instances.HistoryParams{
            .event_type = null,
            .from = null,
            .to = null,
            .cursor = null,
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
}

// ---------------------------------------------------------------------------
// TC-API-05-12: page_size validation (≤0 → 422, >200 → 422)
// ---------------------------------------------------------------------------

test "TC-API-05-12a: handleHistory with page_size=0 returns HTTP 422 INVALID_PAGE_SIZE" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    // Use a syntactically valid UUID so the handler reaches page_size validation.
    const valid_uuid = "00000000-0000-0000-0000-000000000001";
    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        valid_uuid,
        instances.HistoryParams{
            .event_type = null,
            .from = null,
            .to = null,
            .cursor = null,
            .page_size = 0,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_PAGE_SIZE"));
}

test "TC-API-05-12b: handleHistory with page_size=201 returns HTTP 422 INVALID_PAGE_SIZE" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const valid_uuid = "00000000-0000-0000-0000-000000000001";
    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        valid_uuid,
        instances.HistoryParams{
            .event_type = null,
            .from = null,
            .to = null,
            .cursor = null,
            .page_size = 201,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_PAGE_SIZE"));
}

test "TC-API-05-12c: handleHistory with page_size=1 (valid boundary) passes page_size check" {
    // page_size=1 is valid. The handler will proceed to try to access the
    // store (readHistory). Since we pass undefined, this will crash at runtime.
    // Use SkipZigTest as this requires a real store.
    return error.SkipZigTest;
}

test "TC-API-05-12d: handleHistory with page_size=200 (valid boundary) passes page_size check" {
    // page_size=200 is valid. Requires real store.
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// TC-API-05-06: from > to → HTTP 422 INVALID_TIMESTAMP_RANGE
// ---------------------------------------------------------------------------

test "TC-API-05-06: handleHistory with from > to returns HTTP 422 INVALID_TIMESTAMP_RANGE" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const valid_uuid = "00000000-0000-0000-0000-000000000001";
    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        valid_uuid,
        instances.HistoryParams{
            .event_type = null,
            .from = "2026-06-01T00:00:00Z",
            .to = "2026-01-01T00:00:00Z",
            .cursor = null,
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_TIMESTAMP_RANGE"));
}

// ---------------------------------------------------------------------------
// TC-API-05-18: invalid from timestamp → HTTP 422 INVALID_TIMESTAMP
// ---------------------------------------------------------------------------

test "TC-API-05-18: handleHistory with unparseable from returns HTTP 422 INVALID_TIMESTAMP" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const valid_uuid = "00000000-0000-0000-0000-000000000001";
    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        valid_uuid,
        instances.HistoryParams{
            .event_type = null,
            .from = "not-a-date",
            .to = null,
            .cursor = null,
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_TIMESTAMP"));
}

// ---------------------------------------------------------------------------
// TC-API-05-19: invalid to timestamp → HTTP 422 INVALID_TIMESTAMP
// ---------------------------------------------------------------------------

test "TC-API-05-19: handleHistory with unparseable to returns HTTP 422 INVALID_TIMESTAMP" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const valid_uuid = "00000000-0000-0000-0000-000000000001";
    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        valid_uuid,
        instances.HistoryParams{
            .event_type = null,
            .from = null,
            .to = "garbage-timestamp",
            .cursor = null,
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_TIMESTAMP"));
}

// ---------------------------------------------------------------------------
// TC-API-05-14: ISO 8601 timestamp parsing — valid formats
// ---------------------------------------------------------------------------

test "TC-API-05-14a: valid UTC timestamp '2026-01-15T10:30:00Z' parses successfully" {
    // Valid timestamp. Validation passes, then handler tries to access store.
    // Requires real store → SkipZigTest.
    return error.SkipZigTest;
}

test "TC-API-05-14b: valid timestamp with milliseconds '2026-01-15T10:30:00.123Z' parses" {
    return error.SkipZigTest;
}

test "TC-API-05-14c: valid timestamp with microseconds '2026-01-15T10:30:00.123456Z' parses" {
    return error.SkipZigTest;
}

test "TC-API-05-14d: valid timestamp with timezone offset '+05:00' parses" {
    return error.SkipZigTest;
}

test "TC-API-05-14e: valid timestamp with negative timezone offset '-03:00' parses" {
    return error.SkipZigTest;
}

test "TC-API-05-14f: timestamp missing 'T' separator fails with INVALID_TIMESTAMP" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const valid_uuid = "00000000-0000-0000-0000-000000000001";
    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        valid_uuid,
        instances.HistoryParams{
            .event_type = null,
            .from = "2026-01-15 10:30:00Z", // space instead of T
            .to = null,
            .cursor = null,
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_TIMESTAMP"));
}

test "TC-API-05-14g: timestamp without timezone suffix fails with INVALID_TIMESTAMP" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const valid_uuid = "00000000-0000-0000-0000-000000000001";
    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        valid_uuid,
        instances.HistoryParams{
            .event_type = null,
            .from = "2026-01-15T10:30:00", // no Z or offset
            .to = null,
            .cursor = null,
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_TIMESTAMP"));
}

test "TC-API-05-14h: timestamp too short fails with INVALID_TIMESTAMP" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const valid_uuid = "00000000-0000-0000-0000-000000000001";
    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        valid_uuid,
        instances.HistoryParams{
            .event_type = null,
            .from = "2026-01Z", // too short
            .to = null,
            .cursor = null,
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_TIMESTAMP"));
}

// ---------------------------------------------------------------------------
// TC-API-05-10: Invalid cursor format → HTTP 422 INVALID_CURSOR
// ---------------------------------------------------------------------------

test "TC-API-05-10a: handleHistory with non-base64url cursor returns HTTP 422 INVALID_CURSOR" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const valid_uuid = "00000000-0000-0000-0000-000000000001";
    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        valid_uuid,
        instances.HistoryParams{
            .event_type = null,
            .from = null,
            .to = null,
            .cursor = "!!!invalid!!!",
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_CURSOR"));
}

test "TC-API-05-10b: handleHistory with empty cursor string returns HTTP 422 INVALID_CURSOR" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const valid_uuid = "00000000-0000-0000-0000-000000000001";
    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        valid_uuid,
        instances.HistoryParams{
            .event_type = null,
            .from = null,
            .to = null,
            .cursor = "",
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    // Empty string will fail base64urlDecode (zero-length output or will decode to empty).
    // The behavior depends on the base64url decode implementation.
    // In our implementation, an empty string produces empty output but then the
    // "Must start with H:" check will fail.
    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_CURSOR"));
}

// ---------------------------------------------------------------------------
// TC-API-05-17: Cross-endpoint cursor → HTTP 422 INVALID_CURSOR
// ---------------------------------------------------------------------------

test "TC-API-05-17: handleHistory with wrong-prefix cursor (T: prefix) returns HTTP 422 INVALID_CURSOR" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const valid_uuid = "00000000-0000-0000-0000-000000000001";

    // Encode "T:123:456" — wrong prefix for this endpoint.
    const raw_cursor = "T:123:456";
    const encoded = try base64urlEncode(alloc, raw_cursor);
    defer alloc.free(encoded);

    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        valid_uuid,
        instances.HistoryParams{
            .event_type = null,
            .from = null,
            .to = null,
            .cursor = encoded,
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_CURSOR"));
}

test "TC-API-05-17b: handleHistory with no-prefix cursor rejects with INVALID_CURSOR" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const valid_uuid = "00000000-0000-0000-0000-000000000001";

    // Encode "123:456" — no prefix at all.
    const raw_cursor = "123:456";
    const encoded = try base64urlEncode(alloc, raw_cursor);
    defer alloc.free(encoded);

    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        valid_uuid,
        instances.HistoryParams{
            .event_type = null,
            .from = null,
            .to = null,
            .cursor = encoded,
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_CURSOR"));
}

// ---------------------------------------------------------------------------
// TC-API-05-11: Expired cursor (>24h) → HTTP 410 CURSOR_EXPIRED
// ---------------------------------------------------------------------------

test "TC-API-05-11: handleHistory with expired cursor returns HTTP 410 CURSOR_EXPIRED" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const valid_uuid = "00000000-0000-0000-0000-000000000001";

    // Create a cursor with an old timestamp (~48 hours ago).
    // currentMicrosecondTimestamp() will be called inside handleHistory.
    // We use a very old timestamp to guarantee expiry.
    const old_us: i64 = 1000; // Unix epoch + 1ms — definitely > 24h ago.
    const raw_cursor = try std.fmt.allocPrint(alloc, "H:{d}:42", .{old_us});
    defer alloc.free(raw_cursor);
    const encoded = try base64urlEncode(alloc, raw_cursor);
    defer alloc.free(encoded);

    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        valid_uuid,
        instances.HistoryParams{
            .event_type = null,
            .from = null,
            .to = null,
            .cursor = encoded,
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 410), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "CURSOR_EXPIRED"));
}

// ---------------------------------------------------------------------------
// TC-API-05-16: Valid cursor decode → passes cursor validation
// ---------------------------------------------------------------------------

test "TC-API-05-16: handleHistory with valid recent cursor decodes successfully" {
    // A cursor with a current timestamp decodes fine, but then the handler
    // tries to access the store (readHistory). Requires real store → SkipZigTest.
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// TC-API-05-10c: cursor with wrong number of segments → HTTP 422
// ---------------------------------------------------------------------------

test "TC-API-05-10c: cursor with only one colon after H prefix returns HTTP 422 INVALID_CURSOR" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const valid_uuid = "00000000-0000-0000-0000-000000000001";

    // Encode "H:42" — only one segment after "H:" (missing the sequence number colon).
    const raw_cursor = "H:42";
    const encoded = try base64urlEncode(alloc, raw_cursor);
    defer alloc.free(encoded);

    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        valid_uuid,
        instances.HistoryParams{
            .event_type = null,
            .from = null,
            .to = null,
            .cursor = encoded,
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_CURSOR"));
}

// ---------------------------------------------------------------------------
// Cursor: non-integer cursor timestamp → HTTP 422
// ---------------------------------------------------------------------------

test "TC-API-05-10d: cursor with non-numeric timestamp returns HTTP 422 INVALID_CURSOR" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const valid_uuid = "00000000-0000-0000-0000-000000000001";

    // Encode "H:abc:42" — non-numeric timestamp.
    const raw_cursor = "H:abc:42";
    const encoded = try base64urlEncode(alloc, raw_cursor);
    defer alloc.free(encoded);

    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        valid_uuid,
        instances.HistoryParams{
            .event_type = null,
            .from = null,
            .to = null,
            .cursor = encoded,
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_CURSOR"));
}

// ---------------------------------------------------------------------------
// Cursor: non-numeric sequence number → HTTP 422
// ---------------------------------------------------------------------------

test "TC-API-05-10e: cursor with non-numeric sequence returns HTTP 422 INVALID_CURSOR" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const valid_uuid = "00000000-0000-0000-0000-000000000001";

    // Encode "H:123:xyz" — non-numeric sequence number.
    const raw_cursor = "H:123:xyz";
    const encoded = try base64urlEncode(alloc, raw_cursor);
    defer alloc.free(encoded);

    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        valid_uuid,
        instances.HistoryParams{
            .event_type = null,
            .from = null,
            .to = null,
            .cursor = encoded,
            .page_size = 50,
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_CURSOR"));
}

// ---------------------------------------------------------------------------
// Combined validation: invalid UUID + invalid page_size → UUID check wins
// ---------------------------------------------------------------------------

test "TC-API-05-combined: invalid UUID takes precedence over page_size validation" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;
    const result = instances.handleHistory(
        &dummy_store,
        alloc,
        "bad-uuid",
        instances.HistoryParams{
            .event_type = null,
            .from = null,
            .to = null,
            .cursor = null,
            .page_size = 0, // also invalid, but UUID check comes first
        },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_INSTANCE_ID"));
}

// ---------------------------------------------------------------------------
// Edge case: HistoryParams with all filters → passes validation, needs store
// ---------------------------------------------------------------------------

test "TC-API-05-edge: valid UUID, valid timestamps, valid page_size reaches store" {
    // All validation passes → handler calls readHistory → needs real store.
    return error.SkipZigTest;
}
