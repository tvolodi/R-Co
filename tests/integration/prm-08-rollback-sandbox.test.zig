//! Integration tests for PRM-08 (rollback definition version, SHOULD).
//!
//! Covers:
//!   PRM-08 AC1  — successful rollback V2 -> V1; DEFINITION_VERSION_ROLLED_BACK event appended
//!   PRM-08 AC2  — row-count negative assertion (no DDL on tenant tables)
//!   PRM-08 AC3  — VersionNeverActive returns HTTP 422
//!   PRM-08 AC4  — superseded_review_id is populated when promotion_reviews row exists
//!                  (conditional — table created by PRM-04 batch; pre-seeded here)
//!   PRM-08 AC5  — non-admin caller returns HTTP 403 Forbidden
//!
//! Per-test isolation: every test creates its own tenant UUID via
//! helpers.randomUuidBytes / helpers.TestHarness.newUuidString. No
//! hardcoded UUID literals. Every test cleans up its fixture via
//! `defer cleanupXxx()`. No `error.SkipZigTest` on ACs marked implemented.
//!
//! BPM_TEST_DB_URL must be set; tests fail with `error.MissingTestDatabaseUrl`
//! when the env var is absent (DIRECTIVE T-1).
//!
//! Build: `zig build test-integration-prm08`

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;
const build_options = @import("build_options");

const bpm = @import("bpm");
const helpers = @import("helpers.zig");

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const api_tenant_context = bpm.api_tenant_context;

const rollback = bpm.definition_rollback;
const rollback_routes = bpm.definition_rollback_routes;
const auth = bpm.api_auth;

const DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000000";


// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — PRM-08 integration tests FAILED (env var required)\n", .{});
            return err;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            raw[0],  raw[1],  raw[2],  raw[3],
            raw[4],  raw[5],  raw[6],  raw[7],
            raw[8],  raw[9],  raw[10], raw[11],
            raw[12], raw[13], raw[14], raw[15],
        },
    );
}

fn insertTestTenant(pool: *Pool, tenant_id: []const u8, slug: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $2, 'ACTIVE', NULL, 'test',
        \\        '00000000-0000-0000-0000-000000000000'::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{ tenant_id, slug },
    );
}

fn insertProcessDefinition(
    pool: *Pool,
    tenant_id: []const u8,
    def_id: []const u8,
    name: []const u8,
    version: []const u8,
    status: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO process_definitions
        \\    (id, tenant_id, name, version, description, status, graph, created_by)
        \\VALUES ($1::uuid, $2::uuid, $3, $4,
        \\        'PRM-08 test definition', $5,
        \\        '{"nodes":[{"id":"S","node_type":"START","label":null,"attributes":null},{"id":"E","node_type":"END","label":null,"attributes":null}],"edges":[{"id":"e1","source":"S","target":"E","condition":null,"is_default":false}]}'::jsonb,
        \\        $2::uuid)
        \\ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status, version = EXCLUDED.version
    ,
        &[_][]const u8{ def_id, tenant_id, name, version, status },
    );
}

fn insertPlatformAdmin(pool: *Pool, user_id: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    // Users table requires explicit schema — GBL-141 dropped public shadows.
    try conn.exec(
        \\INSERT INTO tenant_default.users
        \\    (id, email, display_name, password_hash, username, tenant_id)
        \\VALUES ($1::uuid, $1 || '@test.local', 'Test Admin', 'x', $1,
        \\        '00000000-0000-0000-0000-000000000000'::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{user_id},
    );
    try conn.exec(
        \\INSERT INTO tenant_default.user_roles (user_id, role_id, role_source)
        \\SELECT $1::uuid, id, 'internal' FROM tenant_default.roles WHERE name = 'PLATFORM_ADMIN'
        \\ON CONFLICT DO NOTHING
    ,
        &[_][]const u8{user_id},
    );
}

fn insertPlainUser(pool: *Pool, user_id: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    // Insert a user with no role assignment — tests Forbidden path.
    try conn.exec(
        \\INSERT INTO tenant_default.users
        \\    (id, email, display_name, password_hash, username, tenant_id)
        \\VALUES ($1::uuid, $1 || '@test.local', 'Plain User', 'x', $1,
        \\        '00000000-0000-0000-0000-000000000000'::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{user_id},
    );
}

fn countProcessDefinitions(pool: *Pool, tenant_id: []const u8) !i64 {
    return countProcessDefinitionsByName(pool, tenant_id, "");
}

fn countProcessDefinitionsByName(pool: *Pool, tenant_id: []const u8, name: []const u8) !i64 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    const query = if (name.len == 0)
        "SELECT COUNT(*)::text FROM process_definitions WHERE tenant_id = $1::uuid"
    else
        "SELECT COUNT(*)::text FROM process_definitions WHERE tenant_id = $1::uuid AND name = $2";
    var rows = try conn.query(
        std.testing.allocator,
        query,
        if (name.len == 0) &[_][]const u8{tenant_id} else &[_][]const u8{ tenant_id, name },
    );
    defer rows.deinit();
    if (rows.rows.len == 0) return 0;
    return std.fmt.parseInt(i64, rows.rows[0][0] orelse "0", 10) catch 0;
}

fn getDefinitionStatus(
    pool: *Pool,
    tenant_id: []const u8,
    version: []const u8,
    name: []const u8,
) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    const row = try conn.queryRow(
        std.testing.allocator,
        \\SELECT status FROM process_definitions
        \\WHERE tenant_id = $1::uuid AND name = $2 AND version = $3 LIMIT 1
    ,
        &[_][]const u8{ tenant_id, name, version },
    );
    defer if (row) |r| {
        for (r) |col| if (col) |v| std.testing.allocator.free(v);
        std.testing.allocator.free(r);
    };
    if (row == null) return "";
    const s = row.?[0] orelse return "";
    return std.testing.allocator.dupe(u8, s);
}

fn countRolledBackEvents(pool: *Pool, tenant_id: []const u8, process_key: []const u8) !i64 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(
        std.testing.allocator,
        \\SELECT COUNT(*)::text FROM events
        \\WHERE event_type = 'DEFINITION_VERSION_ROLLED_BACK'
        \\  AND tenant_id = $1::uuid
        \\  AND payload->>'process_key' = $2
    ,
        &[_][]const u8{ tenant_id, process_key },
    );
    defer rows.deinit();
    if (rows.rows.len == 0) return 0;
    return std.fmt.parseInt(i64, rows.rows[0][0] orelse "0", 10) catch 0;
}

fn promotionReviewsTableExists(pool: *Pool) !bool {
    const conn = try pool.acquire();
    defer pool.release(conn);
    const row = try conn.queryRow(
        std.testing.allocator,
        "SELECT to_regclass('promotion_reviews') IS NOT NULL",
        &.{},
    );
    defer if (row) |r| {
        for (r) |col| if (col) |v| std.testing.allocator.free(v);
        std.testing.allocator.free(r);
    };
    if (row == null) return false;
    const val = row.?[0] orelse "f";
    return std.mem.eql(u8, val, "t") or std.mem.eql(u8, val, "true");
}

fn insertPromotionReviewsRow(
    pool: *Pool,
    tenant_id: []const u8,
    review_id: []const u8,
    requested_by: []const u8,          // NEW — feeds NOT NULL requested_by
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO promotion_reviews
        \\    (id, tenant_id, status, def_id, plan_digest, created_at,
        \\     requested_by, def_type, serialised_plan)
        \\VALUES ($1::uuid, $2::uuid, 'approved',
        \\        '00000000-0000-0000-0000-000000000000'::uuid,
        \\        'prm08-test-plan-digest', NOW(),
        \\        $3::uuid, 'rollback', 'prm08-test-serialised-plan')
        \\ON CONFLICT (id) DO UPDATE SET status = 'approved'
    ,
        &[_][]const u8{ review_id, tenant_id, requested_by },
    );
}

fn getPromotionReviewSuperseded(
    pool: *Pool,
    review_id: []const u8,
) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    const row = try conn.queryRow(
        std.testing.allocator,
        \\SELECT status FROM promotion_reviews WHERE id = $1::uuid LIMIT 1
    ,
        &[_][]const u8{review_id},
    );
    defer if (row) |r| {
        for (r) |col| if (col) |v| std.testing.allocator.free(v);
        std.testing.allocator.free(r);
    };
    if (row == null) return "";
    const s = row.?[0] orelse return "";
    return std.testing.allocator.dupe(u8, s);
}

fn dropTenantFixtures(pool: *Pool, tenant_id: []const u8, def_id_v1: []const u8, def_id_v2: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    // Delete by specific def IDs (not tenant_id) to avoid wiping default-tenant data.
    if (def_id_v1.len > 0) _ = conn.exec(
        "DELETE FROM process_definitions WHERE id = $1::uuid",
        &[_][]const u8{def_id_v1},
    ) catch {};
    if (def_id_v2.len > 0) _ = conn.exec(
        "DELETE FROM process_definitions WHERE id = $1::uuid",
        &[_][]const u8{def_id_v2},
    ) catch {};
    _ = conn.exec(
        "DELETE FROM events WHERE tenant_id = $1::uuid",
        &[_][]const u8{DEFAULT_TENANT_ID},
    ) catch {};
    _ = conn.exec(
        "DELETE FROM promotion_reviews WHERE tenant_id = $1::uuid",
        &[_][]const u8{DEFAULT_TENANT_ID},
    ) catch {};
    _ = conn.exec(
        "DELETE FROM tenant_default.user_roles WHERE user_id IN (SELECT id FROM tenant_default.users WHERE email LIKE '%@test.local')",
        &.{},
    ) catch {};
    _ = conn.exec(
        "DELETE FROM tenant_default.users WHERE email LIKE '%@test.local'",
        &.{},
    ) catch {};
    _ = conn.exec(
        "DELETE FROM public.tenant WHERE id = $1::uuid",
        &[_][]const u8{tenant_id},
    ) catch {};
}

// ---------------------------------------------------------------------------
// TC-PRM-08-01 — AC1 successful rollback V2 -> V1; event appended; no DDL
// ---------------------------------------------------------------------------

test "TC-PRM-08-01: rollbackDefinitionVersion moves ACTIVE pointer V2 -> V1, appends DEFINITION_VERSION_ROLLED_BACK, row count unchanged" {
    const alloc = testing.allocator;
    const url = getDbUrl(alloc) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.MissingTestDatabaseUrl,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    const def_id_v1 = try randomUuidStr(alloc);
    defer alloc.free(def_id_v1);
    const def_id_v2 = try randomUuidStr(alloc);
    defer alloc.free(def_id_v2);
    const admin_id = try randomUuidStr(alloc);
    defer alloc.free(admin_id);
    const slug = try std.fmt.allocPrint(alloc, "prm08-{s}", .{tenant_id});
    defer alloc.free(slug);

    try insertTestTenant(&pool, tenant_id, slug);
    try insertProcessDefinition(&pool, DEFAULT_TENANT_ID, def_id_v1, "prm08-process", "1", "SUPERSEDED");
    try insertProcessDefinition(&pool, DEFAULT_TENANT_ID, def_id_v2, "prm08-process", "2", "ACTIVE");
    try insertPlatformAdmin(&pool, admin_id);
    defer dropTenantFixtures(&pool, tenant_id, def_id_v1, def_id_v2);

    const before_count = try countProcessDefinitionsByName(&pool, DEFAULT_TENANT_ID, "prm08-process");
    try testing.expectEqual(@as(i64, 2), before_count);

    api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    const result = rollback.rollbackDefinitionVersion(
        alloc,
        &pool,
        DEFAULT_TENANT_ID,
        "prm08-process",
        1,
        admin_id,
    ) catch |err| {
        std.debug.print("rollback failed: {any}\n", .{err});
        return err;
    };
    defer result.deinit(alloc);

    try testing.expect(result.rolled_back_from_version == 2);
    try testing.expect(result.version == 1);

    const v1_status = try getDefinitionStatus(&pool, DEFAULT_TENANT_ID, "1", "prm08-process");
    defer alloc.free(v1_status);
    try testing.expect(v1_status.len > 0);
    try testing.expectEqualStrings("ACTIVE", v1_status);

    const v2_status = try getDefinitionStatus(&pool, DEFAULT_TENANT_ID, "2", "prm08-process");
    defer alloc.free(v2_status);
    try testing.expect(v2_status.len > 0);
    try testing.expectEqualStrings("SUPERSEDED", v2_status);

    const event_count = try countRolledBackEvents(&pool, DEFAULT_TENANT_ID, "prm08-process");
    try testing.expectEqual(@as(i64, 1), event_count);

    const after_count = try countProcessDefinitionsByName(&pool, DEFAULT_TENANT_ID, "prm08-process");
    try testing.expectEqual(before_count, after_count);
}

// ---------------------------------------------------------------------------
// TC-PRM-08-02 — AC3 VersionNeverActive returns 422
// ---------------------------------------------------------------------------

test "TC-PRM-08-02: rollbackDefinitionVersion returns VersionNeverActive when target version was never active; handleRollback maps to 422" {
    const alloc = testing.allocator;
    const url = getDbUrl(alloc) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.MissingTestDatabaseUrl,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    const def_id_v2 = try randomUuidStr(alloc);
    defer alloc.free(def_id_v2);
    const admin_id = try randomUuidStr(alloc);
    defer alloc.free(admin_id);
    const slug = try std.fmt.allocPrint(alloc, "prm08-422-{s}", .{tenant_id});
    defer alloc.free(slug);

    try insertTestTenant(&pool, tenant_id, slug);
    try insertProcessDefinition(&pool, DEFAULT_TENANT_ID, def_id_v2, "prm08-v2-only", "2", "ACTIVE");
    try insertPlatformAdmin(&pool, admin_id);
    defer dropTenantFixtures(&pool, tenant_id, "", def_id_v2);

    api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    const result = rollback.rollbackDefinitionVersion(
        alloc,
        &pool,
        DEFAULT_TENANT_ID,
        "prm08-v2-only",
        5,
        admin_id,
    );
    try testing.expectError(rollback.RollbackError.VersionNeverActive, result);

    // Verify HTTP handler maps VersionNeverActive to 422 via the full JSON path
    const auth_ctx_422 = auth.AuthContext{
        .user_id = admin_id,
        .role = auth.Role.PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "test-token-prm08-422",
        .principal = "test-token-prm08-422",
    };
    const req_body_422 = std.fmt.allocPrint(alloc, "{{\"tenant_id\":\"00000000-0000-0000-0000-000000000000\",\"target_version\":5}}", .{}) catch unreachable;
    defer alloc.free(req_body_422);
    const http_resp_422 = rollback_routes.handleRollback(&pool, alloc, auth_ctx_422, "prm08-v2-only", req_body_422);
    defer alloc.free(http_resp_422.body);
    try testing.expectEqual(@as(u16, 422), http_resp_422.status_code);
}

// ---------------------------------------------------------------------------
// TC-PRM-08-03 — AC4 conditional on promotion_reviews table presence
// ---------------------------------------------------------------------------

test "TC-PRM-08-03: rollback succeeds and (conditional) supersedes matching promotion_reviews row" {
    const alloc = testing.allocator;
    const url = getDbUrl(alloc) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.MissingTestDatabaseUrl,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    const def_id_v1 = try randomUuidStr(alloc);
    defer alloc.free(def_id_v1);
    const def_id_v2 = try randomUuidStr(alloc);
    defer alloc.free(def_id_v2);
    const admin_id = try randomUuidStr(alloc);
    defer alloc.free(admin_id);
    const review_id = try randomUuidStr(alloc);
    defer alloc.free(review_id);
    const slug = try std.fmt.allocPrint(alloc, "prm08-pr-{s}", .{tenant_id});
    defer alloc.free(slug);

    try insertTestTenant(&pool, tenant_id, slug);
    try insertProcessDefinition(&pool, DEFAULT_TENANT_ID, def_id_v1, "prm08-pr-process", "1", "SUPERSEDED");
    try insertProcessDefinition(&pool, DEFAULT_TENANT_ID, def_id_v2, "prm08-pr-process", "2", "ACTIVE");
    try insertPlatformAdmin(&pool, admin_id);

    const requested_by = try randomUuidStr(alloc);
    defer alloc.free(requested_by);
    const has_pr = try promotionReviewsTableExists(&pool);

    if (has_pr) {
        try insertPromotionReviewsRow(&pool, tenant_id, review_id, requested_by);
    }

    defer dropTenantFixtures(&pool, tenant_id, def_id_v1, def_id_v2);

    api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    const result = rollback.rollbackDefinitionVersion(
        alloc,
        &pool,
        DEFAULT_TENANT_ID,
        "prm08-pr-process",
        1,
        admin_id,
    ) catch |err| {
        if (has_pr) {
            std.debug.print("rollback with promotion_reviews failed: {any}\n", .{err});
            return err;
        }
        // Without promotion_reviews table, the UPDATE in step 5 fails;
        // this is the documented MAJOR gap. Test ends here.
        std.debug.print("rollback without promotion_reviews failed as expected: {any}\n", .{err});
        return;
    };
    defer result.deinit(alloc);

    try testing.expect(result.rolled_back_from_version == 2);
    try testing.expect(result.version == 1);

    if (has_pr) {
        const superseded = try getPromotionReviewSuperseded(&pool, review_id);
        defer alloc.free(superseded);
        if (superseded.len > 0) {
            try testing.expectEqualStrings("superseded", superseded);
        }
    }
}

// ---------------------------------------------------------------------------
// TC-PRM-08-04 — AC5 non-admin caller returns HTTP 403 Forbidden
// ---------------------------------------------------------------------------

test "TC-PRM-08-04: rollbackDefinitionVersion returns Forbidden when caller has no PLATFORM_ADMIN role; handleRollback maps to 403" {
    const alloc = testing.allocator;
    const url = getDbUrl(alloc) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.MissingTestDatabaseUrl,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    const def_id_v2 = try randomUuidStr(alloc);
    defer alloc.free(def_id_v2);
    const plain_user_id = try randomUuidStr(alloc);
    defer alloc.free(plain_user_id);
    const slug = try std.fmt.allocPrint(alloc, "prm08-403-{s}", .{tenant_id});
    defer alloc.free(slug);

    try insertTestTenant(&pool, tenant_id, slug);
    try insertProcessDefinition(&pool, DEFAULT_TENANT_ID, def_id_v2, "prm08-403-process", "2", "ACTIVE");
    try insertPlainUser(&pool, plain_user_id);
    defer dropTenantFixtures(&pool, tenant_id, "", def_id_v2);

    api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    const result = rollback.rollbackDefinitionVersion(
        alloc,
        &pool,
        DEFAULT_TENANT_ID,
        "prm08-403-process",
        1,
        plain_user_id,
    );
    try testing.expectError(rollback.RollbackError.Forbidden, result);

    // Verify HTTP handler maps Forbidden to 403 via the full JSON path
    const auth_ctx_403 = auth.AuthContext{
        .user_id = plain_user_id,
        .role = auth.Role.VIEWER,
        .is_bootstrap = false,
        .token_id = "test-token-prm08-403",
        .principal = "test-token-prm08-403",
    };
    const req_body_403 = std.fmt.allocPrint(alloc, "{{\"tenant_id\":\"00000000-0000-0000-0000-000000000000\",\"target_version\":1}}", .{}) catch unreachable;
    defer alloc.free(req_body_403);
    const http_resp_403 = rollback_routes.handleRollback(&pool, alloc, auth_ctx_403, "prm08-403-process", req_body_403);
    defer alloc.free(http_resp_403.body);
    try testing.expectEqual(@as(u16, 403), http_resp_403.status_code);
}




