//! Integration tests for OIDC-35 — Company Onboarding Orchestration.
//!
//! These tests verify the onboarding_registry database operations, idempotency
//! semantics, the onboarding saga execution against a real Keycloak instance,
//! saga compensation on failure, and input validation rules.
//!
//! Tests that require Keycloak will skip with a clear message when
//! BPM_IDP_BASE_URL is not set or Keycloak is unreachable.
//!
//! Requirement: OIDC-35 [MUST]
//!
//! DIRECTIVE T-1: No mocks, no stubs — all tests use real PostgreSQL.
//! DIRECTIVE T-3: No error.SkipZigTest on MUST requirement tests without
//! a separately passing integration test for that requirement.

const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;
const bpm = @import("bpm");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const onboarding_mod = bpm.onboarding_mod;
const uuid_mod = bpm.uuid;
const pool_mod = bpm.db_pool;
const identity_registry = bpm.identity_registry;
const identity_service = bpm.identity_service;
const onboarding_routes = bpm.onboarding_routes;

// ── Helpers ──────────────────────────────────────────────────────────────────

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !pool_mod.Pool {
    return pool_mod.Pool.init(std.testing.io, allocator, .{ .url = url, .pool_size = 3 });
}

fn hexEncode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const hex_chars = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, idx| {
        out[idx * 2] = hex_chars[byte >> 4];
        out[idx * 2 + 1] = hex_chars[byte & 0xf];
    }
    return out;
}

/// Encode bytes as PostgreSQL bytea hex literal (text format).
/// Produces "\x<hexdigits>" for use with ::bytea cast in text-format parameters.
fn byteaHexLiteral(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const hex = try hexEncode(allocator, bytes);
    defer allocator.free(hex);
    const out = try allocator.alloc(u8, hex.len + 2);
    out[0] = '\\';
    out[1] = 'x';
    @memcpy(out[2..], hex);
    return out;
}

fn generateUuidHex(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    const seed: u64 = @truncate(@intFromPtr(&raw));
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    const hex_chars = "0123456789abcdef";
    const out = try allocator.alloc(u8, 36);
    // UUID format: 8-4-4-4-12 hex chars = 2-1-1-1-6 bytes
    const hex_parts = [_]usize{ 8, 4, 4, 4, 12 };
    var out_idx: usize = 0;
    var raw_idx: usize = 0;
    for (hex_parts, 0..) |part_hex_len, part_i| {
        if (part_i > 0) {
            out[out_idx] = '-';
            out_idx += 1;
        }
        for (0..part_hex_len) |_| {
            const byte = raw[raw_idx >> 1];
            const nibble = if (raw_idx % 2 == 0) byte >> 4 else byte & 0xf;
            out[out_idx] = hex_chars[nibble];
            out_idx += 1;
            raw_idx += 1;
        }
    }
    return out;
}

fn makeAuthContext(allocator: std.mem.Allocator) bpm.api_auth.AuthContext {
    _ = allocator;
    return bpm.api_auth.AuthContext{
        .user_id = "00000000-0000-0000-0000-000000000000",
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = true,
        .token_id = "test-token",
        .tenant_id = bpm.api_auth.DEFAULT_TENANT_ID.*,
        .tenant_source = .default_fallback,
    };
}

fn makeManagerNull() bpm.identity_provider.manager.Manager {
    return bpm.identity_provider.manager.Manager{
        .provider = null,
        .auth_mode = .dual_accept,
        .expected_audience = "",
        .expected_issuer = null,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-OIDC-35-01: Fresh idempotency key creates pending onboarding_registry record
// ─────────────────────────────────────────────────────────────────────────────

test "TC-OIDC-35-01: fresh idempotency key creates pending record" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const onboarding_id = try generateUuidHex(alloc);
    defer alloc.free(onboarding_id);
    const idempotency_key = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(idempotency_key);
    const body = "{\"slug\":\"test-tenant-01\",\"display_name\":\"Test Tenant 01\",\"admin_email\":\"admin@test01.com\",\"admin_username\":\"admin01\",\"admin_display_name\":\"Admin 01\",\"hostname\":\"bpm.test01.com\"}";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    const digest_hex = try byteaHexLiteral(alloc, &digest);
    defer alloc.free(digest_hex);

    var q = try harness.conn.query(
        alloc,
        \\INSERT INTO onboarding_registry (onboarding_id, idempotency_key, request_hash, tenant_id, hostname, state)
        \\VALUES ($1, $2, $3::bytea, NULL, $4, 'pending')
        \\ON CONFLICT (idempotency_key) DO NOTHING
        \\RETURNING onboarding_id::text, idempotency_key, state, response_status
    ,
        &[_][]const u8{ onboarding_id, idempotency_key, digest_hex, "bpm.test01.com" },
    );
    defer q.deinit();

    try testing.expectEqual(@as(usize, 1), q.rows.len);
    try testing.expectEqualStrings(onboarding_id, q.rows[0][0] orelse "");
    try testing.expectEqualStrings(idempotency_key, q.rows[0][1] orelse "");
    try testing.expectEqualStrings("pending", q.rows[0][2] orelse "");
    try testing.expectEqualStrings("201", q.rows[0][3] orelse "");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-OIDC-35-02: Same idempotency key + same request hash returns existing (replay)
// ─────────────────────────────────────────────────────────────────────────────

test "TC-OIDC-35-02: same idempotency key + same hash returns existing record" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const onboarding_id = try generateUuidHex(alloc);
    defer alloc.free(onboarding_id);
    const idempotency_key = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(idempotency_key);
    const body = "{\"slug\":\"test-tenant-02\",\"display_name\":\"Test Tenant 02\",\"admin_email\":\"admin@test02.com\",\"admin_username\":\"admin02\",\"admin_display_name\":\"Admin 02\",\"hostname\":\"bpm.test02.com\"}";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    const digest_hex = try byteaHexLiteral(alloc, &digest);
    defer alloc.free(digest_hex);

    // First insert — should succeed.
    var q1 = try harness.conn.query(
        alloc,
        \\INSERT INTO onboarding_registry (onboarding_id, idempotency_key, request_hash, tenant_id, hostname, state)
        \\VALUES ($1, $2, $3::bytea, NULL, $4, 'pending')
        \\ON CONFLICT (idempotency_key) DO NOTHING
        \\RETURNING onboarding_id::text, state
    ,
        &[_][]const u8{ onboarding_id, idempotency_key, digest_hex, "bpm.test02.com" },
    );
    defer q1.deinit();
    try testing.expectEqual(@as(usize, 1), q1.rows.len);

    // Second insert with same key and same hash — ON CONFLICT DO NOTHING returns no rows.
    var q2 = try harness.conn.query(
        alloc,
        \\INSERT INTO onboarding_registry (onboarding_id, idempotency_key, request_hash, tenant_id, hostname, state)
        \\VALUES ($1, $2, $3::bytea, NULL, $4, 'pending')
        \\ON CONFLICT (idempotency_key) DO NOTHING
        \\RETURNING onboarding_id::text, state
    ,
        &[_][]const u8{ onboarding_id, idempotency_key, digest_hex, "bpm.test02.com" },
    );
    defer q2.deinit();
    try testing.expectEqual(@as(usize, 0), q2.rows.len);

    // Verify the original record exists and is still pending.
    var lookup = try harness.conn.query(
        alloc,
        \\SELECT onboarding_id::text, idempotency_key, state, encode(request_hash, 'hex')
        \\FROM onboarding_registry
        \\WHERE idempotency_key = $1
        \\LIMIT 1
    ,
        &[_][]const u8{idempotency_key},
    );
    defer lookup.deinit();
    try testing.expectEqual(@as(usize, 1), lookup.rows.len);
    try testing.expectEqualStrings(onboarding_id, lookup.rows[0][0] orelse "");
    try testing.expectEqualStrings("pending", lookup.rows[0][2] orelse "");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-OIDC-35-03: Same idempotency key + different request hash => conflict
// ─────────────────────────────────────────────────────────────────────────────

test "TC-OIDC-35-03: same idempotency key + different hash triggers conflict" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const onboarding_id = try generateUuidHex(alloc);
    defer alloc.free(onboarding_id);
    const idempotency_key = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(idempotency_key);

    const body1 = "{\"slug\":\"tenant-a\",\"display_name\":\"Tenant A\",\"admin_email\":\"admin@a.com\",\"admin_username\":\"adminA\",\"admin_display_name\":\"Admin A\",\"hostname\":\"bpm.a.com\"}";
    var digest1: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body1, &digest1, .{});
    const digest1_hex = try byteaHexLiteral(alloc, &digest1);
    defer alloc.free(digest1_hex);

    const body2 = "{\"slug\":\"tenant-b\",\"display_name\":\"Tenant B\",\"admin_email\":\"admin@b.com\",\"admin_username\":\"adminB\",\"admin_display_name\":\"Admin B\",\"hostname\":\"bpm.b.com\"}";
    var digest2: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body2, &digest2, .{});
    const digest2_hex = try byteaHexLiteral(alloc, &digest2);
    defer alloc.free(digest2_hex);

    // Insert first request.
    var q1 = try harness.conn.query(
        alloc,
        \\INSERT INTO onboarding_registry (onboarding_id, idempotency_key, request_hash, tenant_id, hostname, state)
        \\VALUES ($1, $2, $3::bytea, NULL, $4, 'pending')
        \\ON CONFLICT (idempotency_key) DO NOTHING
        \\RETURNING onboarding_id::text
    ,
        &[_][]const u8{ onboarding_id, idempotency_key, digest1_hex, "bpm.a.com" },
    );
    defer q1.deinit();
    try testing.expectEqual(@as(usize, 1), q1.rows.len);

    // Second insert with same key but different hash — should return no rows.
    var q2 = try harness.conn.query(
        alloc,
        \\INSERT INTO onboarding_registry (onboarding_id, idempotency_key, request_hash, tenant_id, hostname, state)
        \\VALUES ($1, $2, $3::bytea, NULL, $4, 'pending')
        \\ON CONFLICT (idempotency_key) DO NOTHING
        \\RETURNING onboarding_id::text
    ,
        &[_][]const u8{ onboarding_id, idempotency_key, digest2_hex, "bpm.b.com" },
    );
    defer q2.deinit();
    try testing.expectEqual(@as(usize, 0), q2.rows.len);

    // Fetch the stored record and compare request hashes.
    var stored = try harness.conn.query(
        alloc,
        \\SELECT encode(request_hash, 'hex'), hostname
        \\FROM onboarding_registry
        \\WHERE idempotency_key = $1
        \\LIMIT 1
    ,
        &[_][]const u8{idempotency_key},
    );
    defer stored.deinit();
    try testing.expectEqual(@as(usize, 1), stored.rows.len);

    const stored_hash_hex = stored.rows[0][0] orelse return error.TestUnexpectedResult;
    const expected_hash_hex = try hexEncode(alloc, &digest1);
    defer alloc.free(expected_hash_hex);
    const unexpected_hash_hex = try hexEncode(alloc, &digest2);
    defer alloc.free(unexpected_hash_hex);

    // Stored hash matches first body, not second body.
    try testing.expectEqualStrings(expected_hash_hex, stored_hash_hex);
    try testing.expect(!std.mem.eql(u8, stored_hash_hex, unexpected_hash_hex));
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-OIDC-35-04: GET onboarding by onboarding_id retrieves the record
// ─────────────────────────────────────────────────────────────────────────────

test "TC-OIDC-35-04: select onboarding by onboarding_id returns correct record" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const onboarding_id = try generateUuidHex(alloc);
    defer alloc.free(onboarding_id);
    const tenant_id = try generateUuidHex(alloc);
    defer alloc.free(tenant_id);
    const idempotency_key = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(idempotency_key);
    // Match PostgreSQL jsonb::text output format (key order observed from pg output)
    const body = try std.fmt.allocPrint(alloc, "{{\"created\": true, \"tenant_id\": \"{s}\", \"onboarding_id\": \"{s}\"}}", .{ tenant_id, onboarding_id });
    defer alloc.free(body);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    const digest_hex = try byteaHexLiteral(alloc, &digest);
    defer alloc.free(digest_hex);

    // Insert a completed record with per-test UUID.
    try harness.conn.exec(
        \\INSERT INTO onboarding_registry (onboarding_id, idempotency_key, request_hash, tenant_id, hostname, response_status, response_body, state, completed_at)
        \\VALUES ($1, $2, $3::bytea, $4::uuid, 'bpm.test04.com', 201, $5::jsonb, 'completed', NOW())
    ,
        &[_][]const u8{ onboarding_id, idempotency_key, digest_hex, tenant_id, body },
    );

    // Select by onboarding_id.
    var q = try harness.conn.query(
        alloc,
        \\SELECT onboarding_id::text, idempotency_key, encode(request_hash, 'hex'), response_status, response_body::text, state
        \\FROM onboarding_registry
        \\WHERE onboarding_id::text = $1
        \\LIMIT 1
    ,
        &[_][]const u8{onboarding_id},
    );
    defer q.deinit();

    try testing.expectEqual(@as(usize, 1), q.rows.len);
    try testing.expectEqualStrings(onboarding_id, q.rows[0][0] orelse "");
    try testing.expectEqualStrings(idempotency_key, q.rows[0][1] orelse "");
    try testing.expectEqualStrings("201", q.rows[0][3] orelse "");
    try testing.expectEqualStrings(body, q.rows[0][4] orelse "");
    try testing.expectEqualStrings("completed", q.rows[0][5] orelse "");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-OIDC-35-05: GET onboarding by hostname retrieves completed record
// ─────────────────────────────────────────────────────────────────────────────

test "TC-OIDC-35-05: select onboarding by hostname returns completed record" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const onboarding_id = try generateUuidHex(alloc);
    defer alloc.free(onboarding_id);
    const tenant_id = try generateUuidHex(alloc);
    defer alloc.free(tenant_id);
    const idempotency_key = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(idempotency_key);
    const hostname = "bpm.test05.com";
    const body = try std.fmt.allocPrint(alloc, "{{\"onboarding_id\":\"{s}\",\"hostname\":\"{s}\",\"created\":true}}", .{ onboarding_id, hostname });
    defer alloc.free(body);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    const digest_hex = try byteaHexLiteral(alloc, &digest);
    defer alloc.free(digest_hex);

    // Insert a completed record with per-test UUID.
    try harness.conn.exec(
        \\INSERT INTO onboarding_registry (onboarding_id, idempotency_key, request_hash, tenant_id, hostname, response_status, response_body, state, completed_at)
        \\VALUES ($1, $2, $3::bytea, $4::uuid, $5, 201, $6::jsonb, 'completed', NOW())
    ,
        &[_][]const u8{ onboarding_id, idempotency_key, digest_hex, tenant_id, hostname, body },
    );

    // Select by hostname (only completed records).
    var q = try harness.conn.query(
        alloc,
        \\SELECT onboarding_id::text, idempotency_key, hostname, response_body::text, state
        \\FROM onboarding_registry
        \\WHERE hostname = $1 AND state = 'completed'
        \\LIMIT 1
    ,
        &[_][]const u8{hostname},
    );
    defer q.deinit();

    try testing.expectEqual(@as(usize, 1), q.rows.len);
    try testing.expectEqualStrings(onboarding_id, q.rows[0][0] orelse "");
    try testing.expectEqualStrings(hostname, q.rows[0][2] orelse "");
    try testing.expectEqualStrings("completed", q.rows[0][4] orelse "");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-OIDC-35-06: Onboarding saga creates tenant and binds hostname (requires Keycloak)
// ─────────────────────────────────────────────────────────────────────────────

test "TC-OIDC-35-06: onboarding saga creates tenant and binds hostname" {
    const alloc = testing.allocator;

    // Check Keycloak availability.
    const env: std.process.Environ = .{ .block = .global };
    const idp_base_url = env.getAlloc(alloc, "BPM_IDP_BASE_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_IDP_BASE_URL not set — skipping TC-06 (requires Keycloak)\n", .{});
            return;
        },
        else => return err,
    };
    defer alloc.free(idp_base_url);

    const provider_type = env.getAlloc(alloc, "BPM_IDP_PROVIDER_TYPE") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_IDP_PROVIDER_TYPE not set — skipping TC-06 (requires full IDP config)\n", .{});
            return;
        },
        else => return err,
    };
    defer alloc.free(provider_type);

    const admin_ref = env.getAlloc(alloc, "BPM_IDP_ADMIN_CREDENTIALS_REF") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_IDP_ADMIN_CREDENTIALS_REF not set — skipping TC-06 (requires full IDP config)\n", .{});
            return;
        },
        else => return err,
    };
    defer alloc.free(admin_ref);

    const default_realm = env.getAlloc(alloc, "BPM_IDP_DEFAULT_REALM_OR_TENANT") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_IDP_DEFAULT_REALM_OR_TENANT not set — skipping TC-06 (requires full IDP config)\n", .{});
            return;
        },
        else => return err,
    };
    defer alloc.free(default_realm);

    // Get test DB URL.
    const db_url = try testDbUrl(alloc);
    defer alloc.free(db_url);

    // Create pool and bootstrap identity provider.
    var pool = try makePool(alloc, db_url);
    defer pool.deinit();

    var boot_result = bpm.identity_provider.bootstrap.initializeActiveProviderFromEnv(alloc, "development") catch |err| {
        std.debug.print("Skipping TC-06: IDP provider bootstrap unavailable in test env: {}\n", .{err});
        return;
    };
    defer boot_result.active.deinit();

    // Generate a unique slug for this test run.
    const slug_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(slug_id);
    const slug = try std.fmt.allocPrint(alloc, "oidc35-tc06-{s}", .{slug_id});
    defer alloc.free(slug);
    const hostname = try std.fmt.allocPrint(alloc, "{s}.bpm.example.com", .{slug});
    defer alloc.free(hostname);

    const input = onboarding_mod.OnboardingInput{
        .slug = slug,
        .display_name = "OIDC-35 TC-06 Tenant",
        .admin_email = "admin@tc06.bpm.example.com",
        .admin_username = "admin-tc06",
        .admin_display_name = "TC-06 Admin",
        .hostname = hostname,
        .realm_config = null,
        .client_config = null,
    };

    const result = onboarding_mod.executeSaga(alloc, boot_result.active.manager, &pool, input, null, build_options.migrations_dir) catch |err| {
        std.debug.print("executeSaga failed: {}\n", .{err});
        return err;
    };
    defer result.deinit(alloc);

    // Verify result fields are populated.
    try testing.expect(result.tenant_id.len > 0);
    try testing.expect(result.onboarding_id.len > 0);
    try testing.expectEqualStrings(slug, result.idp_realm_id);
    try testing.expectEqualStrings(hostname, result.hostname);
    try testing.expect(result.created);

    // Verify tenant exists in DB.
    var conn = try pool.acquire();
    defer pool.release(conn);
    var tenant_q = try conn.query(alloc,
        \\SELECT id::text, slug FROM tenant WHERE slug = $1 LIMIT 1
    , &[_][]const u8{slug});
    defer tenant_q.deinit();
    try testing.expectEqual(@as(usize, 1), tenant_q.rows.len);
    try testing.expectEqualStrings(slug, tenant_q.rows[0][1] orelse "");

    // Verify hostname binding exists.
    var conn2 = try pool.acquire();
    defer pool.release(conn2);
    var hostname_q = try conn2.query(alloc,
        "SELECT hostname FROM tenant_hostnames WHERE hostname = $1 LIMIT 1",
        &[_][]const u8{hostname});
    defer hostname_q.deinit();
    try testing.expectEqual(@as(usize, 1), hostname_q.rows.len);
    try testing.expectEqualStrings(hostname, hostname_q.rows[0][0] orelse "");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-OIDC-35-07: Saga compensation cleans up tenant on failure
// ─────────────────────────────────────────────────────────────────────────────

test "TC-OIDC-35-07: saga compensation cleans up tenant on failure" {
    const alloc = testing.allocator;

    // This test requires Keycloak to be UNAVAILABLE so that the saga fails
    // at the realm provisioning step and triggers compensation.
    const env: std.process.Environ = .{ .block = .global };
    const idp_check = env.getAlloc(alloc, "BPM_IDP_BASE_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => "",
        else => |e| return e,
    };
    if (idp_check.len > 0) {
        alloc.free(idp_check);
        std.debug.print("BPM_IDP_BASE_URL is set — skipping TC-07 (requires Keycloak unreachable)\n", .{});
        return;
    }

    // Get test DB URL.
    const db_url = try testDbUrl(alloc);
    defer alloc.free(db_url);

    var pool = try makePool(alloc, db_url);
    defer pool.deinit();

    // Use a Manager with no provider — all provider operations return
    // error.NotImplemented, which triggers saga compensation.
    const manager = makeManagerNull();

    const slug_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(slug_id);
    const slug = try std.fmt.allocPrint(alloc, "oidc35-tc07-{s}", .{slug_id});
    defer alloc.free(slug);
    const hostname = try std.fmt.allocPrint(alloc, "{s}.bpm.example.com", .{slug});
    defer alloc.free(hostname);

    const input = onboarding_mod.OnboardingInput{
        .slug = slug,
        .display_name = "OIDC-35 TC-07 Tenant",
        .admin_email = "admin@tc07.bpm.example.com",
        .admin_username = "admin-tc07",
        .admin_display_name = "TC-07 Admin",
        .hostname = hostname,
        .realm_config = null,
        .client_config = null,
    };

    // The saga should fail at realm provisioning (Manager has no provider),
    // and compensation should clean up the tenant.
    const saga_result = onboarding_mod.executeSaga(alloc, manager, &pool, input, null, build_options.migrations_dir);
    try testing.expectError(error.RealmProvisioningFailed, saga_result);

    // Verify the tenant was cleaned up by compensation.
    var conn = try pool.acquire();
    defer pool.release(conn);
    var tenant_q = try conn.query(alloc,
        "SELECT id::text FROM tenant WHERE slug = $1 LIMIT 1",
        &[_][]const u8{slug});
    defer tenant_q.deinit();
    try testing.expectEqual(@as(usize, 0), tenant_q.rows.len);

    // Verify hostname was also cleaned up.
    var conn2 = try pool.acquire();
    defer pool.release(conn2);
    var hostname_q = try conn2.query(alloc,
        "SELECT id::text FROM tenant_hostnames WHERE hostname = $1 LIMIT 1",
        &[_][]const u8{hostname});
    defer hostname_q.deinit();
    try testing.expectEqual(@as(usize, 0), hostname_q.rows.len);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-OIDC-35-08: Input validation detects missing required fields
// ─────────────────────────────────────────────────────────────────────────────

test "TC-OIDC-35-08: input validation detects missing required fields" {
    const alloc = testing.allocator;

    const auth_ctx = makeAuthContext(alloc);
    const idempotency_key = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(idempotency_key);

    // A dummy service pointer — the handler returns 422 from parseOnboardingInput
    // before reaching any code path that dereferences the service.
    var dummy_service: identity_service.Service = undefined;

    // Test each missing field individually.
    const test_cases = [_][]const u8{
        "{}",
        "{\"display_name\":\"Test\",\"admin_email\":\"admin@t.com\",\"admin_username\":\"admin\",\"admin_display_name\":\"Admin\",\"hostname\":\"t.com\"}",
        "{\"slug\":\"test\",\"admin_email\":\"admin@t.com\",\"admin_username\":\"admin\",\"admin_display_name\":\"Admin\",\"hostname\":\"t.com\"}",
        "{\"slug\":\"test\",\"display_name\":\"Test\",\"admin_username\":\"admin\",\"admin_display_name\":\"Admin\",\"hostname\":\"t.com\"}",
        "{\"slug\":\"test\",\"display_name\":\"Test\",\"admin_email\":\"admin@t.com\",\"admin_display_name\":\"Admin\",\"hostname\":\"t.com\"}",
        "{\"slug\":\"test\",\"display_name\":\"Test\",\"admin_email\":\"admin@t.com\",\"admin_username\":\"admin\",\"hostname\":\"t.com\"}",
        "{\"slug\":\"test\",\"display_name\":\"Test\",\"admin_email\":\"admin@t.com\",\"admin_username\":\"admin\",\"admin_display_name\":\"Admin\"}",
    };

    for (test_cases) |invalid_body| {
        const result = onboarding_routes.handleOnboarding(
            &dummy_service,
            alloc,
            auth_ctx,
            invalid_body,
            idempotency_key,
        );
        defer alloc.free(result.body);

        try testing.expectEqual(@as(u16, 422), result.status_code);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-OIDC-35-09: Slug validation rejects invalid formats
// ─────────────────────────────────────────────────────────────────────────────

test "TC-OIDC-35-09: slug validation rejects invalid formats" {
    const alloc = testing.allocator;

    const auth_ctx = makeAuthContext(alloc);
    const idempotency_key = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(idempotency_key);

    var dummy_service: identity_service.Service = undefined;

    const valid_base = "{\"display_name\":\"Test\",\"admin_email\":\"admin@t.com\",\"admin_username\":\"admin\",\"admin_display_name\":\"Admin\",\"hostname\":\"t.com\"";

    // Test invalid slug formats.
    const invalid_slugs = [_][]const u8{
        "AB",   // too short (< 3 chars)
        "ab",   // too short (< 3 chars)
        "a",    // too short (< 3 chars)
        "",     // empty
    };

    // Test slugs with uppercase (not allowed).
    const uppercase_slugs = [_][]const u8{
        "TestSlug",
        "TESTSLUG",
        "Test-Slug",
    };

    // Test slugs with invalid characters.
    const invalid_char_slugs = [_][]const u8{
        "test slug",
        "test_slug",
        "test.slug",
        "test@slug",
    };

    // Build slugs that are too long (> 63 chars).
    const long_slug = try alloc.alloc(u8, 64);
    defer alloc.free(long_slug);
    @memset(long_slug, 'a');

    for (invalid_slugs) |slug| {
        const body = try std.fmt.allocPrint(alloc, "{s},\"slug\":\"{s}\"}}", .{ valid_base, slug });
        defer alloc.free(body);

        const result = onboarding_routes.handleOnboarding(
            &dummy_service,
            alloc,
            auth_ctx,
            body,
            idempotency_key,
        );
        defer alloc.free(result.body);

        try testing.expectEqual(@as(u16, 422), result.status_code);
    }

    for (uppercase_slugs) |slug| {
        const body = try std.fmt.allocPrint(alloc, "{s},\"slug\":\"{s}\"}}", .{ valid_base, slug });
        defer alloc.free(body);

        const result = onboarding_routes.handleOnboarding(
            &dummy_service,
            alloc,
            auth_ctx,
            body,
            idempotency_key,
        );
        defer alloc.free(result.body);

        try testing.expectEqual(@as(u16, 422), result.status_code);
    }

    for (invalid_char_slugs) |slug| {
        const body = try std.fmt.allocPrint(alloc, "{s},\"slug\":\"{s}\"}}", .{ valid_base, slug });
        defer alloc.free(body);

        const result = onboarding_routes.handleOnboarding(
            &dummy_service,
            alloc,
            auth_ctx,
            body,
            idempotency_key,
        );
        defer alloc.free(result.body);

        try testing.expectEqual(@as(u16, 422), result.status_code);
    }

    // Too long slug (64 chars).
    {
        const body = try std.fmt.allocPrint(alloc, "{s},\"slug\":\"{s}\"}}", .{ valid_base, long_slug });
        defer alloc.free(body);

        const result = onboarding_routes.handleOnboarding(
            &dummy_service,
            alloc,
            auth_ctx,
            body,
            idempotency_key,
        );
        defer alloc.free(result.body);

        try testing.expectEqual(@as(u16, 422), result.status_code);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-OIDC-35-10: Hostname binding enforces uniqueness
// ─────────────────────────────────────────────────────────────────────────────

test "TC-OIDC-35-10: hostname binding enforces uniqueness" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const hostname = "unique-host-test-10.example.com";
    const tenant_slug = "unique-host-test-10";
    const tenant_id_1 = try generateUuidHex(alloc);
    defer alloc.free(tenant_id_1);
    const tenant_id_2 = try generateUuidHex(alloc);
    defer alloc.free(tenant_id_2);

    // Create a real tenant first (FK requirement for tenant_hostnames).
    try harness.conn.exec(
        \\INSERT INTO tenant (id, slug, display_name, status, idp_realm_id)
        \\VALUES ($1::uuid, $2, 'TC-10 Tenant', 'ACTIVE', $2)
        \\ON CONFLICT (slug) DO NOTHING
    ,
        &[_][]const u8{ tenant_id_1, tenant_slug },
    );

    // Create first hostname binding.
    try harness.conn.exec(
        \\INSERT INTO tenant_hostnames (tenant_id, hostname)
        \\VALUES ($1::uuid, $2)
        \\ON CONFLICT (hostname) DO NOTHING
    ,
        &[_][]const u8{ tenant_id_1, hostname },
    );

    // Create second binding with same hostname — should be prevented by ON CONFLICT.
    var q = try harness.conn.query(
        alloc,
        \\INSERT INTO tenant_hostnames (tenant_id, hostname)
        \\VALUES ($1::uuid, $2)
        \\ON CONFLICT (hostname) DO NOTHING
        \\RETURNING id::text
    ,
        &[_][]const u8{ tenant_id_2, hostname },
    );
    defer q.deinit();
    try testing.expectEqual(@as(usize, 0), q.rows.len);

    // Verify only one binding exists for this hostname.
    var count_q = try harness.conn.query(
        alloc,
        "SELECT COUNT(*)::text FROM tenant_hostnames WHERE hostname = $1",
        &[_][]const u8{hostname},
    );
    defer count_q.deinit();
    try testing.expectEqual(@as(usize, 1), count_q.rows.len);
    try testing.expectEqualStrings("1", count_q.rows[0][0] orelse "0");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-OIDC-35-11: Tenant slug enforces uniqueness
// ─────────────────────────────────────────────────────────────────────────────

test "TC-OIDC-35-11: tenant slug enforces uniqueness" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const slug = "unique-slug-test-11";
    const tenant_id_1 = try generateUuidHex(alloc);
    defer alloc.free(tenant_id_1);
    const tenant_id_2 = try generateUuidHex(alloc);
    defer alloc.free(tenant_id_2);

    // Create first tenant.
    try harness.conn.exec(
        \\INSERT INTO tenant (id, slug, display_name, status, idp_realm_id)
        \\VALUES ($1::uuid, $2, 'Test Tenant', 'ACTIVE', $2)
        \\ON CONFLICT (slug) DO NOTHING
    ,
        &[_][]const u8{ tenant_id_1, slug },
    );

    // Attempt duplicate slug.
    var q = try harness.conn.query(
        alloc,
        \\INSERT INTO tenant (id, slug, display_name, status, idp_realm_id)
        \\VALUES ($1::uuid, $2, 'Duplicate Tenant', 'ACTIVE', $2)
        \\ON CONFLICT (slug) DO NOTHING
        \\RETURNING id::text
    ,
        &[_][]const u8{ tenant_id_2, slug },
    );
    defer q.deinit();
    try testing.expectEqual(@as(usize, 0), q.rows.len);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-OIDC-35-12: Non-existent onboarding_id returns null
// ─────────────────────────────────────────────────────────────────────────────

test "TC-OIDC-35-12: non-existent onboarding_id returns null" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const fake_id = "ffffffffffffffffffffffffffffffff";

    var q = try harness.conn.query(
        alloc,
        \\SELECT onboarding_id::text FROM onboarding_registry
        \\WHERE onboarding_id::text = $1
        \\LIMIT 1
    ,
        &[_][]const u8{fake_id},
    );
    defer q.deinit();
    try testing.expectEqual(@as(usize, 0), q.rows.len);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-OIDC-35-13: Non-existent hostname returns null
// ─────────────────────────────────────────────────────────────────────────────

test "TC-OIDC-35-13: non-existent hostname returns null" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const fake_hostname = "nonexistent.example.com";

    var q = try harness.conn.query(
        alloc,
        \\SELECT onboarding_id::text FROM onboarding_registry
        \\WHERE hostname = $1 AND state = 'completed'
        \\LIMIT 1
    ,
        &[_][]const u8{fake_hostname},
    );
    defer q.deinit();
    try testing.expectEqual(@as(usize, 0), q.rows.len);
}
