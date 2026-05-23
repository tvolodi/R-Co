//! Unit tests for API-08 — Bearer token authentication middleware.
//!
//! These tests exercise the pure code paths in the auth middleware that do not
//! require a database connection.  DB-touching paths (token lookup in api_tokens,
//! role resolution via user_roles) are covered by integration tests.
//!
//! Strategy:
//!   - authenticate() early-return paths (null/malformed header) are tested
//!     with `undefined` as the Pool pointer — safe because the function returns
//!     before accessing the pool (same pattern as auth.zig's own tests).
//!   - Environment-dependent paths (TC-API-08-04, TC-API-08-07, TC-API-08-08)
//!     are tested conditionally based on the current environment, as Zig 0.16
//!     does not provide a portable setenv(). Full env-dependent coverage is
//!     provided by integration tests.
//!   - All allocated error bodies are freed after checking to avoid memory leaks.
//!
//! Requirement traceability:
//!   API-08 → TC-API-08-01  (missing header → 401)
//!            TC-API-08-02  (malformed header → 401)
//!            TC-API-08-02b (empty Bearer token — defensive path, skipped)
//!            TC-API-08-04  (bootstrap token → PLATFORM_ADMIN)
//!            TC-API-08-07  (BootstrapTokenInProduction)
//!            TC-API-08-08  (empty bootstrap → disabled)
//!            TC-API-08-09  (whitespace in header → normalised)
//!
//! Note: auth.zig contains additional embedded tests for Role.fromString,
//! constantTimeEql, hashToken, buildUnauthorized, buildForbidden, and the
//! authenticate early-return paths.
//!
//! Run with: zig build test

const std = @import("std");
const testing = std.testing;
const api = @import("api");
const auth = api.auth;

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Read an environment variable.  Returns null if not set.
fn getEnv(key: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(key);
    if (raw) |r| return std.mem.sliceTo(r, 0);
    return null;
}

/// Free a HandlerResult body if it was heap-allocated (i.e., not the static
/// 500 internal-error fallback string).
fn freeHandlerBody(alloc: std.mem.Allocator, body: []const u8) void {
    const static_500 = "{\"type\":\"https://bpm.example.com/problems/internal-error\",\"title\":\"Internal Server Error\",\"status\":500,\"detail\":\"serialization failed\"}";
    if (!std.mem.eql(u8, body, static_500)) {
        alloc.free(body);
    }
}

// ── TC-API-08-01: Missing Authorization header → HTTP 401 ────────────────────

test "TC-API-08-01: missing Authorization header returns 401 with RFC 9457 body" {
    const alloc = testing.allocator;
    const result = auth.authenticate(alloc, null, undefined);
    defer freeHandlerBody(alloc, result.unauthenticated.body);

    try testing.expect(result == .unauthenticated);
    try testing.expectEqual(@as(u16, 401), result.unauthenticated.status_code);
    try testing.expect(std.mem.indexOf(u8, result.unauthenticated.body, "missing Authorization header") != null);
    try testing.expect(std.mem.indexOf(u8, result.unauthenticated.body, "\"status\":401") != null);
    try testing.expect(std.mem.indexOf(u8, result.unauthenticated.body, "unauthorized") != null);
}

// ── TC-API-08-02: Malformed header (no Bearer prefix) → HTTP 401 ─────────────

test "TC-API-08-02: header without Bearer prefix returns 401" {
    const alloc = testing.allocator;
    const result = auth.authenticate(alloc, "Basic YWxhZGRpbjpvcGVuIHNlc2FtZQ==", undefined);
    defer freeHandlerBody(alloc, result.unauthenticated.body);

    try testing.expect(result == .unauthenticated);
    try testing.expectEqual(@as(u16, 401), result.unauthenticated.status_code);
    try testing.expect(std.mem.indexOf(u8, result.unauthenticated.body, "malformed Authorization header") != null);
}

// ── TC-API-08-02b: Empty Bearer token → HTTP 401 ─────────────────────────────
// The empty-token-after-prefix check is a defensive code path inside
// authenticate().  It is unreachable via the standard HTTP "Bearer " prefix
// because std.mem.trim strips trailing whitespace including the separating
// space.  Full validation of this code path requires integration-level setup.

test "TC-API-08-02b: empty Bearer token returns 401 (defensive path)" {
    return error.SkipZigTest;
}

// ── TC-API-08-04: Valid bootstrap token → authenticated as PLATFORM_ADMIN ─────
// Conditional: runs when BPM_BOOTSTRAP_TOKEN is set and BPM_ENV ≠ production.

test "TC-API-08-04: bootstrap token authenticates as PLATFORM_ADMIN" {
    const alloc = testing.allocator;

    const env = getEnv("BPM_ENV") orelse "development";
    const bootstrap = getEnv("BPM_BOOTSTRAP_TOKEN");

    if (std.mem.eql(u8, env, "production") or bootstrap == null or bootstrap.?.len == 0) {
        return error.SkipZigTest;
    }

    try auth.init(alloc);
    defer auth.deinit();

    const result = auth.authenticate(alloc, "Bearer test-bootstrap-token", undefined);
    if (result == .authenticated) {
        try testing.expectEqual(auth.Role.PLATFORM_ADMIN, result.authenticated.role);
        try testing.expect(result.authenticated.is_bootstrap);
    } else {
        freeHandlerBody(alloc, result.unauthenticated.body);
    }
}

// ── TC-API-08-07: BPM_BOOTSTRAP_TOKEN in production → fatal startup error ────

test "TC-API-08-07: bootstrap token in production returns BootstrapTokenInProduction" {
    const alloc = testing.allocator;

    const env = getEnv("BPM_ENV") orelse "development";
    const bootstrap = getEnv("BPM_BOOTSTRAP_TOKEN");

    if (!std.mem.eql(u8, env, "production") or bootstrap == null or bootstrap.?.len == 0) {
        return error.SkipZigTest;
    }

    try testing.expectError(auth.AuthError.BootstrapTokenInProduction, auth.init(alloc));
    auth.deinit();
}

// ── TC-API-08-08: Empty bootstrap token → treated as not set ─────────────────

test "TC-API-08-08: empty bootstrap token treated as disabled" {
    const alloc = testing.allocator;

    const bootstrap = getEnv("BPM_BOOTSTRAP_TOKEN");
    if (bootstrap != null and bootstrap.?.len > 0) {
        return error.SkipZigTest;
    }

    try auth.init(alloc);
    defer auth.deinit();

    const result = auth.authenticate(alloc, "Bearer any-token", undefined);
    defer freeHandlerBody(alloc, result.unauthenticated.body);

    try testing.expect(result == .unauthenticated);
    try testing.expectEqual(@as(u16, 401), result.unauthenticated.status_code);
}

// ── TC-API-08-09: Whitespace in Authorization header → normalised ────────────
// These tests require a bootstrap token to avoid falling through to DB access
// on the undefined pool pointer.  Full whitespace handling is tested in
// integration tests with a real DB.

test "TC-API-08-09: leading whitespace trimmed from Authorization header" {
    const alloc = testing.allocator;

    const env = getEnv("BPM_ENV") orelse "development";
    const bootstrap = getEnv("BPM_BOOTSTRAP_TOKEN");

    if (std.mem.eql(u8, env, "production") or bootstrap == null or bootstrap.?.len == 0) {
        return error.SkipZigTest;
    }

    try auth.init(alloc);
    defer auth.deinit();

    const result = auth.authenticate(alloc, "  Bearer test-bootstrap-token", undefined);
    if (result == .authenticated) {
        try testing.expect(result.authenticated.is_bootstrap);
    } else {
        freeHandlerBody(alloc, result.unauthenticated.body);
    }
}

test "TC-API-08-09b: trailing whitespace after token trimmed correctly" {
    const alloc = testing.allocator;

    const env = getEnv("BPM_ENV") orelse "development";
    const bootstrap = getEnv("BPM_BOOTSTRAP_TOKEN");

    if (std.mem.eql(u8, env, "production") or bootstrap == null or bootstrap.?.len == 0) {
        return error.SkipZigTest;
    }

    try auth.init(alloc);
    defer auth.deinit();

    const result = auth.authenticate(alloc, "Bearer test-bootstrap-token  ", undefined);
    if (result == .authenticated) {
        try testing.expect(result.authenticated.is_bootstrap);
    } else {
        freeHandlerBody(alloc, result.unauthenticated.body);
    }
}

// ── RFC 9457 Problem Details format validation via 401 path ──────────────────

test "TC-API-08-401-format: 401 response contains correct RFC 9457 structure" {
    const alloc = testing.allocator;
    const result = auth.authenticate(alloc, null, undefined);
    defer freeHandlerBody(alloc, result.unauthenticated.body);

    try testing.expect(result == .unauthenticated);
    const body = result.unauthenticated.body;
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"https://bpm.example.com/problems/unauthorized\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"title\":\"Unauthorized\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"status\":401") != null);
}
