//! API-01 unit tests: RFC 9457 Problem Details + Content-Type enforcement + response helpers.
//!
//! Covers all test cases in tests/specs/API-01.md (TC-API-01-01 through TC-API-01-22).
//! All tests are pure — no DB, no HTTP server, no network.
//!
//! Modules under test:
//!   src/api/errors.zig               (named import: "errors")
//!   src/api/middleware/content_type.zig (named import: "content_type")
//!   src/api/response.zig             (named import: "response")

const std = @import("std");
const testing = std.testing;
const api = @import("api");
const errors = api.errors;
const content_type = api.content_type;
const response = api.response;

// ── ProblemDetails constructor tests ──────────────────────────────────────────

test "TC-API-01-01: problemBadRequest produces status=400 and type URI contains bad-request" {
    const pd = errors.problemBadRequest("test detail");
    try testing.expectEqual(@as(u16, 400), pd.status);
    try testing.expect(std.mem.indexOf(u8, pd.type, "bad-request") != null);
}

test "TC-API-01-02: problemNotFound produces status=404" {
    const pd = errors.problemNotFound("not found");
    try testing.expectEqual(@as(u16, 404), pd.status);
}

test "TC-API-01-03: problemConflict produces status=409" {
    const pd = errors.problemConflict("conflict");
    try testing.expectEqual(@as(u16, 409), pd.status);
}

test "TC-API-01-04: problemUnprocessable produces status=422" {
    const pd = errors.problemUnprocessable("unprocessable");
    try testing.expectEqual(@as(u16, 422), pd.status);
}

test "TC-API-01-05: problemUnsupportedMediaType produces status=415" {
    const pd = errors.problemUnsupportedMediaType("unsupported");
    try testing.expectEqual(@as(u16, 415), pd.status);
}

test "TC-API-01-06: problemInternalError produces status=500" {
    const pd = errors.problemInternalError("internal");
    try testing.expectEqual(@as(u16, 500), pd.status);
}

test "TC-API-01-07: problemServiceUnavailable produces status=503" {
    const pd = errors.problemServiceUnavailable("unavailable");
    try testing.expectEqual(@as(u16, 503), pd.status);
}

// ── serialise tests ───────────────────────────────────────────────────────────

test "TC-API-01-08: serialise outputs valid JSON with all 4 RFC 9457 fields" {
    const alloc = testing.allocator;
    const pd = errors.problemNotFound("definition not found");
    const json = try errors.serialise(alloc, pd);
    defer alloc.free(json);

    // All four required RFC 9457 fields must be present as JSON keys.
    try testing.expect(std.mem.indexOf(u8, json, "\"type\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"title\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"status\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"detail\"") != null);
    // Output must be a JSON object.
    try testing.expect(json.len >= 2);
    try testing.expectEqual('{', json[0]);
    try testing.expectEqual('}', json[json.len - 1]);
}

test "TC-API-01-09: serialise JSON contains correct numeric status value" {
    const alloc = testing.allocator;
    const pd = errors.problemConflict("already exists");
    const json = try errors.serialise(alloc, pd);
    defer alloc.free(json);

    // Status 409 must appear as an unquoted numeric value.
    try testing.expect(std.mem.indexOf(u8, json, "409") != null);
    // Must not be quoted (RFC 9457 status is a number, not a string).
    try testing.expect(std.mem.indexOf(u8, json, "\"409\"") == null);
}

// ── Content-Type middleware tests ─────────────────────────────────────────────

test "TC-API-01-10: POST with Content-Type application/json passes (returns null)" {
    const result = content_type.checkContentType("POST", "application/json", true);
    try testing.expect(result == null);
}

test "TC-API-01-11: POST with Content-Type text/plain returns 415 ProblemDetails" {
    const result = content_type.checkContentType("POST", "text/plain", true);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u16, 415), result.?.status);
}

test "TC-API-01-12: POST with no Content-Type returns 415 ProblemDetails" {
    const result = content_type.checkContentType("POST", null, true);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u16, 415), result.?.status);
}

test "TC-API-01-13: PUT with Content-Type application/json and body passes (returns null)" {
    const result = content_type.checkContentType("PUT", "application/json", true);
    try testing.expect(result == null);
}

test "TC-API-01-14: PUT with no body returns 400 ProblemDetails" {
    const result = content_type.checkContentType("PUT", null, false);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u16, 400), result.?.status);
}

test "TC-API-01-15: GET passes regardless of Content-Type (returns null)" {
    const result = content_type.checkContentType("GET", null, false);
    try testing.expect(result == null);
}

test "TC-API-01-16: DELETE passes regardless of Content-Type (returns null)" {
    const result = content_type.checkContentType("DELETE", null, false);
    try testing.expect(result == null);
}

test "TC-API-01-17: PATCH with Content-Type application/json passes (returns null)" {
    const result = content_type.checkContentType("PATCH", "application/json", true);
    try testing.expect(result == null);
}

test "TC-API-01-18: PATCH with wrong Content-Type returns 415 ProblemDetails" {
    const result = content_type.checkContentType("PATCH", "text/xml", true);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u16, 415), result.?.status);
}

// ── Response helper tests ─────────────────────────────────────────────────────

test "TC-API-01-19: ok() returns status_code 200" {
    const r = response.ok("{\"id\":\"1\"}");
    try testing.expectEqual(@as(u16, 200), r.status_code);
}

test "TC-API-01-20: created() returns status_code 201" {
    const r = response.created("{\"id\":\"2\"}");
    try testing.expectEqual(@as(u16, 201), r.status_code);
}

test "TC-API-01-21: noContent() returns status_code 204 and empty body" {
    const r = response.noContent();
    try testing.expectEqual(@as(u16, 204), r.status_code);
    try testing.expectEqualStrings("", r.body);
}

test "TC-API-01-22: problemResponse() returns status_code matching ProblemDetails status" {
    const alloc = testing.allocator;
    const pd = errors.problemBadRequest("invalid input");
    const r = response.problemResponse(alloc, pd);
    defer alloc.free(r.body);
    try testing.expectEqual(@as(u16, 400), r.status_code);
}
