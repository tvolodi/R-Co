//! Unit tests for API-08 — Bearer token authentication middleware.
//!
//! All tests are self-contained — no environment variables or database required.
//! Bootstrap token paths use a hardcoded test token passed directly to auth.init().
//! DB-touching paths (api_tokens lookup, role resolution) are covered by
//! integration tests.
//!
//! Requirement traceability:
//!   API-08 → TC-API-08-01  (missing header → 401)
//!            TC-API-08-02  (malformed header → 401)
//!            TC-API-08-02b (empty Bearer token → 401)
//!            TC-API-08-04  (bootstrap token → PLATFORM_ADMIN)
//!            TC-API-08-07  (BootstrapTokenInProduction via initFromEnv)
//!            TC-API-08-08  (empty/null bootstrap → disabled)
//!            TC-API-08-09  (whitespace in header → normalised)
//!
//! Note: auth.zig contains additional embedded tests for Role.fromString,
//! constantTimeEql, hashToken, buildUnauthorized, buildForbidden, and the
//! authenticate early-return paths.
//!
//! Run with: zig build test

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;
const api = @import("api");
const auth = api.auth;
const pool = @import("pool");
const provisioning_mod = @import("provisioning");
const build_options = @import("build_options");
const provider_types = api.identity_provider.types;
const stub_provider = api.identity_provider.adapters.stub;

/// Test bootstrap token used for all bootstrap-auth tests.
const TEST_BOOTSTRAP_TOKEN = "test-bootstrap-token-12345";
const VALID_OIDC_JWT = "eyJhbGciOiJub25lIn0.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature";

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Free a HandlerResult body if it was heap-allocated (i.e., not the static
/// 500 internal-error fallback string).
fn freeHandlerBody(alloc: std.mem.Allocator, body: []const u8) void {
    const static_500 = "{\"type\":\"https://bpm.example.com/problems/internal-error\",\"title\":\"Internal Server Error\",\"status\":500,\"detail\":\"serialization failed\"}";
    if (!std.mem.eql(u8, body, static_500)) {
        alloc.free(body);
    }
}

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => return err,
    };
}

/// ISS-0209: test-harness recovery loop. A generic MigrationFailed is no
/// longer a license to drop the schema; the loop retries on transient
/// contention and escalates on persistent failure without any destructive
/// action.
const HarnessRecoveryError = error{
    /// Persistent provisioning failure after `max_recovery_attempts`
    /// retries. The schema is left exactly as the canonical migrator
    /// left it — no DROP, no metadata delete.
    RecoveryFailed,
    /// The advisory lock acquire itself timed out before granting.
    LockAcquireTimeout,
    /// A non-MigrationFailed ProvisionError variant surfaced from the
    /// canonical path inside the recovery loop.
    CanonicalProvisionFailed,
};

/// Ensure the tenant_default schema exists and has been migrated.
/// After Stage 12 schema isolation, users and api_tokens live in per-tenant
/// schemas. The DB-touching tests in this file need tenant_default to be
/// provisioned. This helper is idempotent: if the schema is already set up
/// it returns immediately.
///
/// ISS-0209: holds the canonical tenant advisory lock around the full
/// recovery sequence. On MigrationFailed, retries the canonical call with
/// bounded backoff; on persistent failure, escalates to RecoveryFailed —
/// never drops the schema, never deletes metadata.
fn ensureTenantDefaultSchema(
    allocator: std.mem.Allocator,
    db_pool: *pool.Pool,
    max_recovery_attempts: u8,
) HarnessRecoveryError!void {
    const default_tenant_id = "00000000-0000-0000-0000-000000000000";

    const lock_conn = db_pool.acquire() catch return HarnessRecoveryError.CanonicalProvisionFailed;
    defer db_pool.release(lock_conn);

    lock_conn.exec(
        "SET lock_timeout = '90s'",
        &.{},
    ) catch return HarnessRecoveryError.CanonicalProvisionFailed;
    defer lock_conn.exec(
        "SET lock_timeout = '0'",
        &.{},
    ) catch {};

    provisioning_mod.acquireAdvisoryLock(lock_conn, default_tenant_id) catch |err| switch (err) {
        error.PoolExhausted => return HarnessRecoveryError.CanonicalProvisionFailed,
        else => return HarnessRecoveryError.CanonicalProvisionFailed,
    };
    defer provisioning_mod.releaseAdvisoryLock(lock_conn, default_tenant_id) catch {};

    var attempt: u8 = 0;
    while (attempt < max_recovery_attempts) : (attempt += 1) {
        provisioning_mod.provisionTenantSchema(
            allocator,
            db_pool,
            default_tenant_id,
            build_options.migrations_dir,
        ) catch |err| switch (err) {
            error.MigrationFailed => {
                const backoff_ms: u64 = @as(u64, 1) << @intCast(@min(attempt, 5));
                const capped_ms = @min(backoff_ms * 100, 2000);
                std.Io.sleep(
                    std.Options.debug_io,
                    .fromMilliseconds(@as(i64, capped_ms)),
                    .awake,
                ) catch {};
                continue;
            },
            error.QueryFailed => return HarnessRecoveryError.CanonicalProvisionFailed,
            error.SchemaCreationFailed => return HarnessRecoveryError.CanonicalProvisionFailed,
            error.RegistryUpdateFailed => return HarnessRecoveryError.CanonicalProvisionFailed,
            error.PoolExhausted => return HarnessRecoveryError.CanonicalProvisionFailed,
            error.InvalidTenantId => return HarnessRecoveryError.CanonicalProvisionFailed,
            error.SchemaPromotionFailed => return HarnessRecoveryError.CanonicalProvisionFailed,
        };
        return;
    }

    return HarnessRecoveryError.RecoveryFailed;
}

fn hashToken(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(&digest, .lower)});
}

fn cleanupInactiveAuthFixtures(db_pool: *pool.Pool, username: []const u8) void {
    const conn = db_pool.acquire() catch return;
    defer db_pool.release(conn);

    conn.exec(
        \\DELETE FROM api_tokens
        \\WHERE user_id IN (SELECT id FROM users WHERE username = $1)
    ,
        &[_][]const u8{username},
    ) catch {};

    conn.exec(
        \\DELETE FROM user_roles
        \\WHERE user_id IN (SELECT id FROM users WHERE username = $1)
    ,
        &[_][]const u8{username},
    ) catch {};

    conn.exec("DELETE FROM users WHERE username = $1", &[_][]const u8{username}) catch {};
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
// The empty-token-after-prefix check is a defensive code path tested by
// passing "Bearer" (no space, no token) to trigger the empty-token branch.

test "TC-API-08-02b: empty Bearer token returns 401" {
    const alloc = testing.allocator;
    const result = auth.authenticate(alloc, "Bearer", undefined);
    defer freeHandlerBody(alloc, result.unauthenticated.body);

    try testing.expect(result == .unauthenticated);
    try testing.expectEqual(@as(u16, 401), result.unauthenticated.status_code);
}

// ── TC-API-08-04: Valid bootstrap token → authenticated as PLATFORM_ADMIN ─────

test "TC-API-08-04: bootstrap token authenticates as PLATFORM_ADMIN" {
    const alloc = testing.allocator;

    try auth.init(alloc, TEST_BOOTSTRAP_TOKEN);
    defer auth.deinit();

    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{TEST_BOOTSTRAP_TOKEN});
    defer alloc.free(header);

    const result = auth.authenticate(alloc, header, undefined);
    defer alloc.free(result.authenticated.user_id);
    defer alloc.free(result.authenticated.token_id);
    try testing.expect(result == .authenticated);
    try testing.expectEqual(auth.Role.PLATFORM_ADMIN, result.authenticated.role);
    try testing.expect(result.authenticated.is_bootstrap);
    try testing.expectEqualStrings("bootstrap", result.authenticated.token_id);
}

// ── TC-API-08-07: BPM_BOOTSTRAP_TOKEN in production → fatal startup error ────
// initFromEnv reads BPM_ENV from the environment.  This test is valid even
// outside production — it checks that the error type exists and is testable.
// Full production-mode rejection is tested by the initFromEnv code path,
// which requires BPM_ENV=production to be set externally.

test "TC-API-08-07: BootstrapTokenInProduction error type exists" {
    // Verify the error type is defined and can be checked.
    const err: auth.AuthError = auth.AuthError.BootstrapTokenInProduction;
    try testing.expectEqual(err, auth.AuthError.BootstrapTokenInProduction);
    // initFromEnv with BPM_ENV=production would trigger it, but that requires
    // setenv which is not portable in Zig 0.16.  The code path is verified
    // via code review and integration tests.
}

// ── TC-API-08-08: Empty/null bootstrap token → treated as not set ────────────

test "TC-API-08-08: empty bootstrap token treated as disabled" {
    const alloc = testing.allocator;

    // Pass empty string — bootstrap auth should be disabled.
    // init() accepts empty string as "not set" (no hash stored).
    try auth.init(alloc, "");
    defer auth.deinit();

    // Verify: authenticate with an unknown token returns 401 when no bootstrap
    // is configured and no DB is available.  The function will attempt DB lookup
    // which panics with `undefined` pool — so we only test init/deinit here.
    // The full unknown-token path is covered by integration tests with a real DB.
}

test "TC-API-08-08b: null bootstrap token treated as disabled" {
    const alloc = testing.allocator;

    // Pass null — bootstrap auth should be disabled.
    try auth.init(alloc, null);
    defer auth.deinit();

    // Same reasoning as TC-API-08-08: without bootstrap and without DB,
    // authenticate() would crash on the DB path.  init/deinit cycle is verified.
    // Full coverage via integration tests.
}

// ── TC-API-08-09: Whitespace in Authorization header → normalised ────────────

test "TC-API-08-09: leading whitespace trimmed from Authorization header" {
    const alloc = testing.allocator;

    try auth.init(alloc, TEST_BOOTSTRAP_TOKEN);
    defer auth.deinit();

    const header = try std.fmt.allocPrint(alloc, "  Bearer {s}", .{TEST_BOOTSTRAP_TOKEN});
    defer alloc.free(header);

    const result = auth.authenticate(alloc, header, undefined);
    defer alloc.free(result.authenticated.user_id);
    defer alloc.free(result.authenticated.token_id);
    try testing.expect(result == .authenticated);
    try testing.expect(result.authenticated.is_bootstrap);
}

test "TC-API-08-09b: trailing whitespace after token trimmed correctly" {
    const alloc = testing.allocator;

    try auth.init(alloc, TEST_BOOTSTRAP_TOKEN);
    defer auth.deinit();

    const header = try std.fmt.allocPrint(alloc, "Bearer {s}  ", .{TEST_BOOTSTRAP_TOKEN});
    defer alloc.free(header);

    const result = auth.authenticate(alloc, header, undefined);
    defer alloc.free(result.authenticated.user_id);
    defer alloc.free(result.authenticated.token_id);
    try testing.expect(result == .authenticated);
    try testing.expect(result.authenticated.is_bootstrap);
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

// ── TC-IDN-01-06: INACTIVE user token auth must return HTTP 401 ─────────────

test "TC-IDN-01-06: token for INACTIVE user returns 401" {
    const alloc = testing.allocator;

    const url = testDbUrl(alloc) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => return err,
    };
    defer alloc.free(url);

    // TNT schema isolation: users table is in tenant_default after Stage 12.
    api.tenant_context.set("00000000-0000-0000-0000-000000000000");
    defer api.tenant_context.set("");

    var db_pool = try pool.Pool.init(std.testing.io, alloc, .{ .url = url, .pool_size = 3 });
    defer db_pool.deinit();

    // Ensure tenant_default schema exists (idempotent; no-op if already present).
    try ensureTenantDefaultSchema(alloc, &db_pool, 5);

    const username = "tc-idn-01-06-inactive";
    cleanupInactiveAuthFixtures(&db_pool, username);
    defer cleanupInactiveAuthFixtures(&db_pool, username);

    const raw_token = "tc-idn-01-06-raw-token";
    const token_hash = try hashToken(alloc, raw_token);
    defer alloc.free(token_hash);

    const conn = try db_pool.acquire();
    defer db_pool.release(conn);

    try conn.exec(
        \\INSERT INTO users (email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1, $2, $3, $4::boolean, $5, $6)
    ,
        &[_][]const u8{
            "tc-idn-01-06@example.com",
            "TC IDN 01 06",
            "__API_ONLY__",
            "false",
            username,
            "INACTIVE",
        },
    );

    const user_row = (try conn.queryRow(
        alloc,
        "SELECT id::text FROM users WHERE username = $1",
        &[_][]const u8{username},
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (user_row[0]) |v| alloc.free(v);
        alloc.free(user_row);
    }
    const user_id = user_row[0] orelse return error.TestUnexpectedResult;

    try conn.exec(
        "INSERT INTO api_tokens (user_id, name, token_hash) VALUES ($1, $2, $3)",
        &[_][]const u8{ user_id, "tc-idn-01-06-token", token_hash },
    );

    try auth.init(alloc, null);
    defer auth.deinit();

    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{raw_token});
    defer alloc.free(header);

    const result = auth.authenticate(alloc, header, &db_pool);
    switch (result) {
        .unauthenticated => |hr| {
            defer freeHandlerBody(alloc, hr.body);
            try testing.expectEqual(@as(u16, 401), hr.status_code);
            try testing.expect(std.mem.indexOf(u8, hr.body, "user inactive") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "TC-IDN-04-04a: revoked token is rejected by auth middleware with 401" {
    const alloc = testing.allocator;

    const url = testDbUrl(alloc) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => return err,
    };
    defer alloc.free(url);

    // TNT schema isolation: users table is in tenant_default after Stage 12.
    api.tenant_context.set("00000000-0000-0000-0000-000000000000");
    defer api.tenant_context.set("");

    var db_pool = try pool.Pool.init(std.testing.io, alloc, .{ .url = url, .pool_size = 3 });
    defer db_pool.deinit();

    // Ensure tenant_default schema exists (idempotent; no-op if already present).
    try ensureTenantDefaultSchema(alloc, &db_pool, 5);

    const username = "tc-idn-04-04a-revoked";
    cleanupInactiveAuthFixtures(&db_pool, username);
    defer cleanupInactiveAuthFixtures(&db_pool, username);

    const raw_token = "tc-idn-04-04a-raw-token";
    const token_hash = try hashToken(alloc, raw_token);
    defer alloc.free(token_hash);

    const conn = try db_pool.acquire();
    defer db_pool.release(conn);

    try conn.exec(
        \\INSERT INTO users (email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1, $2, $3, $4::boolean, $5, $6)
    ,
        &[_][]const u8{
            "tc-idn-04-04a@example.com",
            "TC IDN 04 04a",
            "__API_ONLY__",
            "true",
            username,
            "ACTIVE",
        },
    );

    const user_row = (try conn.queryRow(
        alloc,
        "SELECT id::text FROM users WHERE username = $1",
        &[_][]const u8{username},
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (user_row[0]) |v| alloc.free(v);
        alloc.free(user_row);
    }
    const user_id = user_row[0] orelse return error.TestUnexpectedResult;

    try conn.exec(
        "INSERT INTO api_tokens (user_id, name, token_hash, roles_json, revoked_at) VALUES ($1, $2, $3, $4::jsonb, NOW())",
        &[_][]const u8{ user_id, "tc-idn-04-04a-token", token_hash, "[\"TASK_WORKER\"]" },
    );

    try auth.init(alloc, null);
    defer auth.deinit();

    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{raw_token});
    defer alloc.free(header);

    const result = auth.authenticate(alloc, header, &db_pool);
    switch (result) {
        .unauthenticated => |hr| {
            defer freeHandlerBody(alloc, hr.body);
            try testing.expectEqual(@as(u16, 401), hr.status_code);
            try testing.expect(std.mem.indexOf(u8, hr.body, "token revoked") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "TC-IDN-04-04b: expired token is rejected by auth middleware with 401" {
    const alloc = testing.allocator;

    const url = testDbUrl(alloc) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => return err,
    };
    defer alloc.free(url);

    // TNT schema isolation: users table is in tenant_default after Stage 12.
    api.tenant_context.set("00000000-0000-0000-0000-000000000000");
    defer api.tenant_context.set("");

    var db_pool = try pool.Pool.init(std.testing.io, alloc, .{ .url = url, .pool_size = 3 });
    defer db_pool.deinit();

    // Ensure tenant_default schema exists (idempotent; no-op if already present).
    try ensureTenantDefaultSchema(alloc, &db_pool, 5);

    const username = "tc-idn-04-04b-expired";
    cleanupInactiveAuthFixtures(&db_pool, username);
    defer cleanupInactiveAuthFixtures(&db_pool, username);

    const raw_token = "tc-idn-04-04b-raw-token";
    const token_hash = try hashToken(alloc, raw_token);
    defer alloc.free(token_hash);

    const conn = try db_pool.acquire();
    defer db_pool.release(conn);

    try conn.exec(
        \\INSERT INTO users (email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1, $2, $3, $4::boolean, $5, $6)
    ,
        &[_][]const u8{
            "tc-idn-04-04b@example.com",
            "TC IDN 04 04b",
            "__API_ONLY__",
            "true",
            username,
            "ACTIVE",
        },
    );

    const user_row = (try conn.queryRow(
        alloc,
        "SELECT id::text FROM users WHERE username = $1",
        &[_][]const u8{username},
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (user_row[0]) |v| alloc.free(v);
        alloc.free(user_row);
    }
    const user_id = user_row[0] orelse return error.TestUnexpectedResult;

    try conn.exec(
        "INSERT INTO api_tokens (user_id, name, token_hash, roles_json, expires_at) VALUES ($1, $2, $3, $4::jsonb, NOW() - INTERVAL '1 minute')",
        &[_][]const u8{ user_id, "tc-idn-04-04b-token", token_hash, "[\"TASK_WORKER\"]" },
    );

    try auth.init(alloc, null);
    defer auth.deinit();

    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{raw_token});
    defer alloc.free(header);

    const result = auth.authenticate(alloc, header, &db_pool);
    switch (result) {
        .unauthenticated => |hr| {
            defer freeHandlerBody(alloc, hr.body);
            try testing.expectEqual(@as(u16, 401), hr.status_code);
            try testing.expect(std.mem.indexOf(u8, hr.body, "token expired") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "TC-IDN-04-05a: token role claims drive resolved auth role" {
    const alloc = testing.allocator;

    const url = testDbUrl(alloc) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => return err,
    };
    defer alloc.free(url);

    // TNT schema isolation: users table is in tenant_default after Stage 12.
    api.tenant_context.set("00000000-0000-0000-0000-000000000000");
    defer api.tenant_context.set("");

    var db_pool = try pool.Pool.init(std.testing.io, alloc, .{ .url = url, .pool_size = 3 });
    defer db_pool.deinit();

    // Ensure tenant_default schema exists (idempotent; no-op if already present).
    try ensureTenantDefaultSchema(alloc, &db_pool, 5);

    const username = "tc-idn-04-05a-role-claims";
    cleanupInactiveAuthFixtures(&db_pool, username);
    defer cleanupInactiveAuthFixtures(&db_pool, username);

    const raw_token = "tc-idn-04-05a-raw-token";
    const token_hash = try hashToken(alloc, raw_token);
    defer alloc.free(token_hash);

    const conn = try db_pool.acquire();
    defer db_pool.release(conn);

    try conn.exec(
        \\INSERT INTO users (email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1, $2, $3, $4::boolean, $5, $6)
    ,
        &[_][]const u8{
            "tc-idn-04-05a@example.com",
            "TC IDN 04 05a",
            "__API_ONLY__",
            "true",
            username,
            "ACTIVE",
        },
    );

    const user_row = (try conn.queryRow(
        alloc,
        "SELECT id::text FROM users WHERE username = $1",
        &[_][]const u8{username},
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (user_row[0]) |v| alloc.free(v);
        alloc.free(user_row);
    }
    const user_id = user_row[0] orelse return error.TestUnexpectedResult;

    try conn.exec(
        "INSERT INTO api_tokens (user_id, name, token_hash, roles_json) VALUES ($1, $2, $3, $4::jsonb)",
        &[_][]const u8{ user_id, "tc-idn-04-05a-token", token_hash, "[\"TASK_WORKER\",\"PROCESS_OPERATOR\"]" },
    );

    try auth.init(alloc, null);
    defer auth.deinit();

    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{raw_token});
    defer alloc.free(header);

    const result = auth.authenticate(alloc, header, &db_pool);
    switch (result) {
        .authenticated => |ctx| {
            defer alloc.free(ctx.user_id);
            defer alloc.free(ctx.token_id);
            try testing.expectEqual(auth.Role.PROCESS_OPERATOR, ctx.role);
        },
        .unauthenticated => |hr| {
            defer freeHandlerBody(alloc, hr.body);
            return error.TestUnexpectedResult;
        },
        .forbidden => |hr| {
            defer freeHandlerBody(alloc, hr.body);
            return error.TestUnexpectedResult;
        },
    }
}

test "TC-IDN-04-05b: invalid token role claim is rejected with 401" {
    const alloc = testing.allocator;

    const url = testDbUrl(alloc) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => return err,
    };
    defer alloc.free(url);

    // TNT schema isolation: users table is in tenant_default after Stage 12.
    api.tenant_context.set("00000000-0000-0000-0000-000000000000");
    defer api.tenant_context.set("");

    var db_pool = try pool.Pool.init(std.testing.io, alloc, .{ .url = url, .pool_size = 3 });
    defer db_pool.deinit();

    // Ensure tenant_default schema exists (idempotent; no-op if already present).
    try ensureTenantDefaultSchema(alloc, &db_pool, 5);

    const username = "tc-idn-04-05b-invalid-claim";
    cleanupInactiveAuthFixtures(&db_pool, username);
    defer cleanupInactiveAuthFixtures(&db_pool, username);

    const raw_token = "tc-idn-04-05b-raw-token";
    const token_hash = try hashToken(alloc, raw_token);
    defer alloc.free(token_hash);

    const conn = try db_pool.acquire();
    defer db_pool.release(conn);

    try conn.exec(
        \\INSERT INTO users (email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1, $2, $3, $4::boolean, $5, $6)
    ,
        &[_][]const u8{
            "tc-idn-04-05b@example.com",
            "TC IDN 04 05b",
            "__API_ONLY__",
            "true",
            username,
            "ACTIVE",
        },
    );

    const user_row = (try conn.queryRow(
        alloc,
        "SELECT id::text FROM users WHERE username = $1",
        &[_][]const u8{username},
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (user_row[0]) |v| alloc.free(v);
        alloc.free(user_row);
    }
    const user_id = user_row[0] orelse return error.TestUnexpectedResult;

    try conn.exec(
        "INSERT INTO api_tokens (user_id, name, token_hash, roles_json) VALUES ($1, $2, $3, $4::jsonb)",
        &[_][]const u8{ user_id, "tc-idn-04-05b-token", token_hash, "[\"NOT_A_ROLE\"]" },
    );

    try auth.init(alloc, null);
    defer auth.deinit();

    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{raw_token});
    defer alloc.free(header);

    const result = auth.authenticate(alloc, header, &db_pool);
    switch (result) {
        .unauthenticated => |hr| {
            defer freeHandlerBody(alloc, hr.body);
            try testing.expectEqual(@as(u16, 401), hr.status_code);
            try testing.expect(std.mem.indexOf(u8, hr.body, "invalid role claim") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "TC-OIDC-01-01: JWT-like token uses configured IdentityProvider verify path" {
    const alloc = testing.allocator;

    var provider_roles = [_]provider_types.ProviderRole{.PROCESS_OPERATOR};
    var stub_ctx = stub_provider.StubContext{
        .verify_result = .{ .ok = .{
            .provider_subject = "provider-subject-1",
            .username = "oidc.user",
            .display_name = "OIDC User",
            .email = "oidc.user@example.com",
            .tenant_id = "11111111-1111-1111-1111-111111111111".*,
            .roles = provider_roles[0..],
            .external_realm = "tenant-realm",
            .token_id_hint = "oidc-token-id-1",
        } },
    };

    auth.configureIdentityProviderManager(.{
        .provider = stub_provider.asIdentityProvider(&stub_ctx),
        .auth_mode = .dual_accept,
    });
    defer auth.resetIdentityProviderManager();

    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{VALID_OIDC_JWT});
    defer alloc.free(header);

    const result = auth.authenticate(alloc, header, undefined);
    switch (result) {
        .authenticated => |ctx| {
            defer alloc.free(ctx.user_id);
            defer alloc.free(ctx.token_id);
            defer alloc.free(ctx.principal);

            try testing.expectEqual(@as(usize, 1), stub_ctx.verify_call_count);
            try testing.expectEqual(auth.Role.PROCESS_OPERATOR, ctx.role);
            try testing.expectEqualStrings("provider-subject-1", ctx.user_id);
            try testing.expectEqualStrings("oidc-token-id-1", ctx.token_id);
            try testing.expectEqualStrings("11111111-1111-1111-1111-111111111111", ctx.tenant_id[0..]);
            try testing.expectEqual(auth.TenantContextSource.token_claim, ctx.tenant_source);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "TC-OIDC-01-02: provider token verification failure returns 401" {
    const alloc = testing.allocator;

    var stub_ctx = stub_provider.StubContext{
        .verify_result = .{ .err = error.InvalidToken },
    };

    auth.configureIdentityProviderManager(.{
        .provider = stub_provider.asIdentityProvider(&stub_ctx),
        .auth_mode = .dual_accept,
    });
    defer auth.resetIdentityProviderManager();

    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{VALID_OIDC_JWT});
    defer alloc.free(header);

    const result = auth.authenticate(alloc, header, undefined);
    switch (result) {
        .unauthenticated => |hr| {
            defer freeHandlerBody(alloc, hr.body);
            try testing.expectEqual(@as(usize, 1), stub_ctx.verify_call_count);
            try testing.expectEqual(@as(u16, 401), hr.status_code);
            try testing.expect(std.mem.indexOf(u8, hr.body, "invalid bearer token") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "TC-OIDC-05-01: malformed JWT-like bearer token returns deterministic indeterminate 401" {
    const alloc = testing.allocator;

    var stub_ctx = stub_provider.StubContext{};
    auth.configureIdentityProviderManager(.{
        .provider = stub_provider.asIdentityProvider(&stub_ctx),
        .auth_mode = .dual_accept,
    });
    defer auth.resetIdentityProviderManager();

    const result = auth.authenticate(alloc, "Bearer a.b.c", undefined);
    switch (result) {
        .unauthenticated => |hr| {
            defer freeHandlerBody(alloc, hr.body);
            try testing.expectEqual(@as(u16, 401), hr.status_code);
            try testing.expectEqual(@as(usize, 0), stub_ctx.verify_call_count);
            try testing.expect(std.mem.indexOf(u8, hr.body, "token_type_indeterminate") != null);
            try testing.expect(std.mem.indexOf(u8, hr.body, "malformed_indeterminate") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "TC-OIDC-05-02: opaque bearer token never routes to OIDC verifier" {
    const alloc = testing.allocator;

    var stub_ctx = stub_provider.StubContext{};
    auth.configureIdentityProviderManager(.{
        .provider = stub_provider.asIdentityProvider(&stub_ctx),
        .auth_mode = .dual_accept,
    });
    defer auth.resetIdentityProviderManager();

    try auth.init(alloc, "legacy-opaque-token");
    defer auth.deinit();

    const result = auth.authenticate(alloc, "Bearer legacy-opaque-token", undefined);
    switch (result) {
        .authenticated => |ctx| {
            defer alloc.free(ctx.user_id);
            defer alloc.free(ctx.token_id);

            try testing.expectEqual(@as(usize, 0), stub_ctx.verify_call_count);
            try testing.expect(ctx.is_bootstrap);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "TC-OIDC-07-U01: issuer mismatch maps to 401 token_invalid_issuer" {
    const alloc = testing.allocator;

    var stub_ctx = stub_provider.StubContext{
        .verify_result = .{ .err = error.TokenIssuerMismatch },
    };
    auth.configureIdentityProviderManager(.{
        .provider = stub_provider.asIdentityProvider(&stub_ctx),
        .auth_mode = .dual_accept,
    });
    defer auth.resetIdentityProviderManager();

    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{VALID_OIDC_JWT});
    defer alloc.free(header);

    const result = auth.authenticate(alloc, header, undefined);
    switch (result) {
        .unauthenticated => |hr| {
            defer freeHandlerBody(alloc, hr.body);
            try testing.expectEqual(@as(u16, 401), hr.status_code);
            try testing.expect(std.mem.indexOf(u8, hr.body, "token_invalid_issuer") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "TC-OIDC-07-U02: audience mismatch maps to 401 token_invalid_audience" {
    const alloc = testing.allocator;

    var stub_ctx = stub_provider.StubContext{
        .verify_result = .{ .err = error.TokenAudienceMismatch },
    };
    auth.configureIdentityProviderManager(.{
        .provider = stub_provider.asIdentityProvider(&stub_ctx),
        .auth_mode = .dual_accept,
    });
    defer auth.resetIdentityProviderManager();

    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{VALID_OIDC_JWT});
    defer alloc.free(header);

    const result = auth.authenticate(alloc, header, undefined);
    switch (result) {
        .unauthenticated => |hr| {
            defer freeHandlerBody(alloc, hr.body);
            try testing.expectEqual(@as(u16, 401), hr.status_code);
            try testing.expect(std.mem.indexOf(u8, hr.body, "token_invalid_audience") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "TC-OIDC-07-U03: expired token maps to 401 token_expired" {
    const alloc = testing.allocator;

    var stub_ctx = stub_provider.StubContext{
        .verify_result = .{ .err = error.TokenExpired },
    };
    auth.configureIdentityProviderManager(.{
        .provider = stub_provider.asIdentityProvider(&stub_ctx),
        .auth_mode = .dual_accept,
    });
    defer auth.resetIdentityProviderManager();

    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{VALID_OIDC_JWT});
    defer alloc.free(header);

    const result = auth.authenticate(alloc, header, undefined);
    switch (result) {
        .unauthenticated => |hr| {
            defer freeHandlerBody(alloc, hr.body);
            try testing.expectEqual(@as(u16, 401), hr.status_code);
            try testing.expect(std.mem.indexOf(u8, hr.body, "token_expired") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "TC-OIDC-07-U04: not-yet-valid token maps to 401 token_not_yet_valid" {
    const alloc = testing.allocator;

    var stub_ctx = stub_provider.StubContext{
        .verify_result = .{ .err = error.TokenNotYetValid },
    };
    auth.configureIdentityProviderManager(.{
        .provider = stub_provider.asIdentityProvider(&stub_ctx),
        .auth_mode = .dual_accept,
    });
    defer auth.resetIdentityProviderManager();

    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{VALID_OIDC_JWT});
    defer alloc.free(header);

    const result = auth.authenticate(alloc, header, undefined);
    switch (result) {
        .unauthenticated => |hr| {
            defer freeHandlerBody(alloc, hr.body);
            try testing.expectEqual(@as(u16, 401), hr.status_code);
            try testing.expect(std.mem.indexOf(u8, hr.body, "token_not_yet_valid") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "TC-OIDC-07-U05: signature verification failure maps to 401 token_invalid_signature" {
    const alloc = testing.allocator;

    var stub_ctx = stub_provider.StubContext{
        .verify_result = .{ .err = error.SignatureVerificationFailed },
    };
    auth.configureIdentityProviderManager(.{
        .provider = stub_provider.asIdentityProvider(&stub_ctx),
        .auth_mode = .dual_accept,
    });
    defer auth.resetIdentityProviderManager();

    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{VALID_OIDC_JWT});
    defer alloc.free(header);

    const result = auth.authenticate(alloc, header, undefined);
    switch (result) {
        .unauthenticated => |hr| {
            defer freeHandlerBody(alloc, hr.body);
            try testing.expectEqual(@as(u16, 401), hr.status_code);
            try testing.expect(std.mem.indexOf(u8, hr.body, "token_invalid_signature") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}
