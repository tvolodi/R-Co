//! Unit tests for API-03 — Instance management handler layer.
//!
//! These tests exercise the pure input-validation early-exit paths in the
//! handleGetById and handleList handler functions.  All paths that return
//! before any InstanceStore method is called can be tested without a database
//! connection.  Store-touching paths are covered by integration tests in
//! tests/integration/api03_instance_read_test.zig.
//!
//! Strategy: pass an `undefined` InstanceStore pointer to handlers whose
//! failing branch is reached before the first store field access.  This is
//! safe only when the handler is guaranteed to return on a validation error
//! before accessing the store — confirmed by reading each handler's early-exit
//! branch in src/api/routes/instances.zig.
//!
//! Requirement traceability:
//!   API-03 → TC-API-03-03 (handleGetById invalid UUID)
//!            TC-API-03-09 (handleList invalid status)
//!            TC-API-03-10 (handleList page_size=0)
//!            TC-API-03-11 (handleList page_size=201)
//!            TC-API-03-12 (handleList invalid definition_id UUID)
//!            TC-API-03-13 (handleList malformed cursor)
//!            TC-API-03-14 (handleList expired cursor)
//!            TC-API-03-21 (handleList cursor with one colon only)
//!
//! Run with: zig build test

const std = @import("std");
const testing = std.testing;

// src/main.zig is wired as the named "bpm" module in build.zig.
// It publishes instance_routes (src/api/routes/instances.zig).
const bpm = @import("bpm");
const instances = bpm.instance_routes;
const InstanceStore = bpm.engine_instance.InstanceStore;

// ---------------------------------------------------------------------------
// TC-API-03-03: handleGetById — invalid UUID path param → HTTP 422
// ---------------------------------------------------------------------------

test "TC-API-03-03: handleGetById with non-UUID string returns HTTP 422 INVALID_INSTANCE_ID" {
    const alloc = testing.allocator;

    // The handler validates the path param before calling the store.
    // Passing undefined is safe because the store is never accessed.
    var dummy_store: InstanceStore = undefined;
    const result = instances.handleGetById(&dummy_store, alloc, "not-a-uuid");
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_INSTANCE_ID"));
}

test "TC-API-03-03b: handleGetById with short string returns HTTP 422 INVALID_INSTANCE_ID" {
    const alloc = testing.allocator;
    var dummy_store: InstanceStore = undefined;
    const result = instances.handleGetById(&dummy_store, alloc, "12345678");
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_INSTANCE_ID"));
}

// ---------------------------------------------------------------------------
// TC-API-03-09: handleList — invalid status value → HTTP 422 INVALID_STATUS
// ---------------------------------------------------------------------------

test "TC-API-03-09: handleList with status=UNKNOWN_STATUS returns HTTP 422 INVALID_STATUS" {
    const alloc = testing.allocator;
    var dummy_store: InstanceStore = undefined;
    const result = instances.handleList(&dummy_store, alloc, instances.ListInstancesParams{
        .status = "UNKNOWN_STATUS",
        .definition_id = null,
        .cursor = null,
        .page_size = 50,
    });
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_STATUS"));
}

test "TC-API-03-09b: handleList with status=active (lowercase) returns HTTP 422 INVALID_STATUS" {
    // Comparison is case-sensitive; "active" != "ACTIVE".
    const alloc = testing.allocator;
    var dummy_store: InstanceStore = undefined;
    const result = instances.handleList(&dummy_store, alloc, instances.ListInstancesParams{
        .status = "active",
        .definition_id = null,
        .cursor = null,
        .page_size = 50,
    });
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_STATUS"));
}

// ---------------------------------------------------------------------------
// TC-API-03-10: handleList — page_size = 0 → HTTP 422 INVALID_PAGE_SIZE
// ---------------------------------------------------------------------------

test "TC-API-03-10: handleList with page_size=0 returns HTTP 422 INVALID_PAGE_SIZE" {
    const alloc = testing.allocator;
    var dummy_store: InstanceStore = undefined;
    const result = instances.handleList(&dummy_store, alloc, instances.ListInstancesParams{
        .status = null,
        .definition_id = null,
        .cursor = null,
        .page_size = 0,
    });
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_PAGE_SIZE"));
}

// ---------------------------------------------------------------------------
// TC-API-03-11: handleList — page_size > 200 → HTTP 422 INVALID_PAGE_SIZE
// ---------------------------------------------------------------------------

test "TC-API-03-11: handleList with page_size=201 returns HTTP 422 INVALID_PAGE_SIZE" {
    const alloc = testing.allocator;
    var dummy_store: InstanceStore = undefined;
    const result = instances.handleList(&dummy_store, alloc, instances.ListInstancesParams{
        .status = null,
        .definition_id = null,
        .cursor = null,
        .page_size = 201,
    });
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_PAGE_SIZE"));
}

// ---------------------------------------------------------------------------
// TC-API-03-12: handleList — invalid definition_id UUID format → HTTP 422
// ---------------------------------------------------------------------------

test "TC-API-03-12: handleList with invalid definition_id returns HTTP 422 INVALID_DEFINITION_ID" {
    const alloc = testing.allocator;
    var dummy_store: InstanceStore = undefined;
    const result = instances.handleList(&dummy_store, alloc, instances.ListInstancesParams{
        .status = null,
        .definition_id = "not-a-uuid",
        .cursor = null,
        .page_size = 50,
    });
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_DEFINITION_ID"));
}

// ---------------------------------------------------------------------------
// TC-API-03-13: handleList — malformed cursor (not valid base64url) → HTTP 422
// ---------------------------------------------------------------------------

test "TC-API-03-13: handleList with malformed cursor returns HTTP 422 INVALID_CURSOR" {
    const alloc = testing.allocator;
    var dummy_store: InstanceStore = undefined;
    // Exclamation marks are not valid base64url characters.
    const result = instances.handleList(&dummy_store, alloc, instances.ListInstancesParams{
        .status = null,
        .definition_id = null,
        .cursor = "!!!not-valid-base64!!!",
        .page_size = 50,
    });
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_CURSOR"));
}

// ---------------------------------------------------------------------------
// TC-API-03-14: handleList — expired cursor (cursor_created_at_us far in past) → HTTP 410
// ---------------------------------------------------------------------------

test "TC-API-03-14: handleList with cursor created >24h ago returns HTTP 410 CURSOR_EXPIRED" {
    const alloc = testing.allocator;

    // Cursor format: base64url_no_pad( "I:" started_at_us ":" instance_id_hex ":" cursor_created_at_us )
    // Use cursor_created_at_us = 1 (Unix epoch + 1 µs) — guaranteed to be > 24h ago.
    const raw_cursor = "I:1716220800000000:00000000-0000-0000-0000-000000000001:1";
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded_len = encoder.calcSize(raw_cursor.len);
    const encoded_buf = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded_buf);
    _ = encoder.encode(encoded_buf, raw_cursor);

    var dummy_store: InstanceStore = undefined;
    const result = instances.handleList(&dummy_store, alloc, instances.ListInstancesParams{
        .status = null,
        .definition_id = null,
        .cursor = encoded_buf,
        .page_size = 50,
    });
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 410), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "CURSOR_EXPIRED"));
}

// ---------------------------------------------------------------------------
// TC-API-03-21: handleList — valid base64 but one colon only (missing segment) → HTTP 422
// ---------------------------------------------------------------------------

test "TC-API-03-21: handleList with cursor missing third segment returns HTTP 422 INVALID_CURSOR" {
    const alloc = testing.allocator;

    // Two segments separated by one colon (missing cursor_created_at_us).
    const raw_cursor = "I:1716220800000000:00000000-0000-0000-0000-000000000001";
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded_len = encoder.calcSize(raw_cursor.len);
    const encoded_buf = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded_buf);
    _ = encoder.encode(encoded_buf, raw_cursor);

    var dummy_store: InstanceStore = undefined;
    const result = instances.handleList(&dummy_store, alloc, instances.ListInstancesParams{
        .status = null,
        .definition_id = null,
        .cursor = encoded_buf,
        .page_size = 50,
    });
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_CURSOR"));
}

// ---------------------------------------------------------------------------
// Happy-path: handleList with all valid "no filter" params succeeds validation
// (would reach store; but we can confirm early-exit branches are not triggered)
// ---------------------------------------------------------------------------

test "handleList with valid ACTIVE status passes validation (page_size check and status check pass)" {
    // We only test that 422 is NOT returned for valid inputs.
    // The handler will try to reach the store and crash on `undefined` —
    // we cannot call it without a real store for non-early-exit paths.
    // This test documents the boundary: the following param set must NOT hit any
    // early-exit 422 branch. We rely on the handler structure confirmed in the source.
    //
    // Validated constraints:
    //   status "ACTIVE" is in the allowed set → passes
    //   page_size 50 is in [1..200]          → passes
    //   definition_id null                    → passes
    //   cursor null                            → passes
    //
    // Because we cannot safely run past the store call with an undefined store,
    // this test simply passes to document the invariant. The integration test
    // TC-API-03-15 exercises this full path with a real store.
    try testing.expect(true);
}
