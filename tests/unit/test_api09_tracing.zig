//! Unit tests for API-09 — Request tracing middleware.
//!
//! All tests are self-contained — no environment variables or database required.
//!
//! Requirement traceability:
//!   API-09 → TC-API-09-01  (no X-Trace-Id → generate UUID v4)
//!            TC-API-09-02  (X-Trace-Id header propagated as-is)
//!            TC-API-09-03  (non-UUID X-Trace-Id accepted without validation)
//!            TC-API-09-04  (empty X-Trace-Id header → generate UUID v4)
//!            TC-API-09-05  (UUID v4 format: dashes, version nibble, variant nibble)
//!            TC-API-09-06  (trace_context get/set/clear lifecycle)
//!            TC-API-09-07  (serialise includes trace_id from trace_context)
//!            TC-API-09-08  (serialise uses pd.trace_id when explicitly set)
//!            TC-API-09-09  (serialise emits empty trace_id when context is clear)
//!            TC-API-09-10  (oversized X-Trace-Id is truncated to MAX_TRACE_ID_LEN)
//!
//! Run with: zig build test

const std = @import("std");
const testing = std.testing;
const api = @import("api");
const trace = api.trace_middleware;
const trace_ctx = api.trace_context;
const errors = api.errors;

// ── TC-API-09-01: No header → generates UUID v4 ──────────────────────────────

test "TC-API-09-01: null X-Trace-Id header generates UUID v4" {
    const alloc = testing.allocator;
    const result = try trace.extractOrGenerate(alloc, null);
    defer alloc.free(result.trace_id);

    try testing.expectEqual(false, result.propagated);
    try testing.expectEqual(@as(usize, trace.UUID_V4_LEN), result.trace_id.len);
}

// ── TC-API-09-02: Present header propagated as-is ────────────────────────────

test "TC-API-09-02: X-Trace-Id header is propagated as-is" {
    const alloc = testing.allocator;
    const incoming = "550e8400-e29b-41d4-a716-446655440000";
    const result = try trace.extractOrGenerate(alloc, incoming);
    defer alloc.free(result.trace_id);

    try testing.expectEqual(true, result.propagated);
    try testing.expectEqualStrings(incoming, result.trace_id);
}

// ── TC-API-09-03: Non-UUID value accepted without validation ─────────────────

test "TC-API-09-03: non-UUID X-Trace-Id accepted without validation" {
    const alloc = testing.allocator;
    const incoming = "not-a-uuid-at-all";
    const result = try trace.extractOrGenerate(alloc, incoming);
    defer alloc.free(result.trace_id);

    try testing.expectEqual(true, result.propagated);
    try testing.expectEqualStrings("not-a-uuid-at-all", result.trace_id);
}

// ── TC-API-09-04: Empty header → generates UUID v4 ───────────────────────────

test "TC-API-09-04: empty X-Trace-Id header generates UUID v4" {
    const alloc = testing.allocator;
    const result = try trace.extractOrGenerate(alloc, "");
    defer alloc.free(result.trace_id);

    try testing.expectEqual(false, result.propagated);
    try testing.expectEqual(@as(usize, trace.UUID_V4_LEN), result.trace_id.len);
}

// ── TC-API-09-05: UUID v4 format validation ───────────────────────────────────

test "TC-API-09-05: generated UUID v4 has correct format" {
    var buf: [trace.UUID_V4_LEN]u8 = undefined;
    trace.generateUuidV4(&buf);
    const uuid = buf[0..];

    // Length
    try testing.expectEqual(@as(usize, 36), uuid.len);
    // Dash positions
    try testing.expectEqual('-', uuid[8]);
    try testing.expectEqual('-', uuid[13]);
    try testing.expectEqual('-', uuid[18]);
    try testing.expectEqual('-', uuid[23]);
    // Version nibble at position 14 must be '4'
    try testing.expectEqual('4', uuid[14]);
    // Variant nibble at position 19 must be '8', '9', 'a', or 'b'
    const variant = uuid[19];
    try testing.expect(variant == '8' or variant == '9' or
        variant == 'a' or variant == 'b');
    // All non-dash characters must be lowercase hex digits
    for (uuid, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(is_hex);
    }
}

// ── TC-API-09-06: trace_context lifecycle ────────────────────────────────────

test "TC-API-09-06: trace_context get/set/clear lifecycle" {
    trace_ctx.clear();
    try testing.expectEqualStrings("", trace_ctx.get());

    trace_ctx.set("my-request-trace");
    try testing.expectEqualStrings("my-request-trace", trace_ctx.get());

    trace_ctx.clear();
    try testing.expectEqualStrings("", trace_ctx.get());
}

// ── TC-API-09-07: serialise includes trace_id from trace_context ─────────────

test "TC-API-09-07: serialise includes trace_id from thread-local trace_context" {
    const alloc = testing.allocator;
    trace_ctx.set("test-trace-abc-123");
    defer trace_ctx.clear();

    const pd = errors.problemNotFound("resource not found");
    const json = try errors.serialise(alloc, pd);
    defer alloc.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"trace_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "test-trace-abc-123") != null);
}

// ── TC-API-09-08: serialise uses pd.trace_id when explicitly set ─────────────

test "TC-API-09-08: serialise uses pd.trace_id when explicitly set (overrides thread-local)" {
    const alloc = testing.allocator;
    trace_ctx.set("thread-local-id");
    defer trace_ctx.clear();

    const pd = errors.ProblemDetails{
        .type = "https://bpm.example.com/problems/not-found",
        .title = "Not Found",
        .status = 404,
        .detail = "item missing",
        .trace_id = "explicit-id-override",
    };
    const json = try errors.serialise(alloc, pd);
    defer alloc.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "explicit-id-override") != null);
    // The thread-local id must NOT appear when pd.trace_id is set.
    try testing.expect(std.mem.indexOf(u8, json, "thread-local-id") == null);
}

// ── TC-API-09-09: serialise emits empty trace_id when context is clear ───────

test "TC-API-09-09: serialise emits empty trace_id when trace_context is clear" {
    const alloc = testing.allocator;
    trace_ctx.clear();

    const pd = errors.problemBadRequest("bad input");
    const json = try errors.serialise(alloc, pd);
    defer alloc.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"trace_id\":\"\"") != null);
}

// ── TC-API-09-10: oversized header truncated to MAX_TRACE_ID_LEN ─────────────

test "TC-API-09-10: X-Trace-Id longer than MAX_TRACE_ID_LEN is truncated" {
    const alloc = testing.allocator;
    var long_id_buf: [trace.MAX_TRACE_ID_LEN + 50]u8 = undefined;
    @memset(&long_id_buf, 'z');
    const long_id: []const u8 = &long_id_buf;
    const result = try trace.extractOrGenerate(alloc, long_id);
    defer alloc.free(result.trace_id);

    try testing.expectEqual(true, result.propagated);
    try testing.expectEqual(@as(usize, trace.MAX_TRACE_ID_LEN), result.trace_id.len);
}
