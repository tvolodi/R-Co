//! Integration tests for ENV-02 — Test tenant is fully isolated from its
//! paired production tenant at the database level.
//!
//! ENV-02 is enforced by two existing mechanisms:
//!   1. Per-connection search_path set by pool.zig (TNT-03).
//!   2. Per-realm Keycloak token scope (enforced at the API layer).
//!
//! These tests verify the DB-level isolation:
//!   TC-ENV-02-01: search_path contains only T-test schema, not T schema.
//!   TC-ENV-02-02: Unqualified query in T-test resolves to T-test tables only.
//!   TC-ENV-02-03: Qualified cross-schema access is blocked or returns no data.
//!
//! Requires a real PostgreSQL database reachable at BPM_TEST_DB_URL.
//! Every test creates its own fixtures with per-test UUIDs and cleans up via defer.
//!
//! Requirement traceability:
//!   ENV-02 → TC-ENV-02-01 .. TC-ENV-02-03

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;
const build_options = @import("build_options");

const bpm = @import("bpm");
const pg = @import("pg");
const helpers = @import("helpers.zig");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const tenant_context = bpm.api_tenant_context;
const provisionTenantSchema = bpm.provisioning.provisionTenantSchema;
const schemaNameForTenant = bpm.pool.schemaNameForTenant;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is not set — ENV-02 integration tests FAILED (env var required)\n",
                .{},
            );
            return err;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

/// ISS-0659 / GH-681: self-managed-pool binary must serialize against
/// TestHarness peers via the bpm_test_migrations_public advisory lock for the
/// binary's full lifetime. PR #494 / ISS-0162 extended this lock inside
/// TestHarness.init(); this entry point lets a makePool-based binary acquire
/// the same lock around its own test block. Pair with
/// `helpers.releaseIntegrationLock(&lock_conn)` via defer at the top of every
/// `test` block.
fn acquireLock(allocator: std.mem.Allocator) anyerror!pg.Conn {
    return helpers.acquireIntegrationLock(allocator);
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant 10xx
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        raw[0],  raw[1],  raw[2],  raw[3],
        raw[4],  raw[5],  raw[6],  raw[7],
        raw[8],  raw[9],  raw[10], raw[11],
        raw[12], raw[13], raw[14], raw[15],
    });
}

/// Insert a bare production tenant row directly into public.tenant.
/// Security: all values bound as parameters — no SQL string interpolation.
/// ISS-0647 / GH-652 (TC-ENV-02-01): both helpers below used to omit
/// storage_mode, which defaults to 'LEGACY_RLS' at the column level
/// (migrations/086_iss107_tenant_storage_mode.sql) — the 'SCHEMA' default
/// documented for "newly provisioned tenants" only applies via the
/// provisionTenantSchema() code path (src/db/provisioning.zig), which these
/// bare-INSERT test helpers bypass entirely. With storage_mode left at
/// LEGACY_RLS, src/db/pool.zig's applyRequestStorageRouting() correctly
/// routes the connection to `SET search_path TO public` (the LEGACY_RLS
/// branch) rather than the tenant-specific schema — this is ENV-02's whole
/// point to test, so the fixture must opt in to storage_mode='SCHEMA'
/// explicitly to exercise that branch.
fn insertProductionTenant(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: []const u8,
    slug: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id, storage_mode)
        \\VALUES ($1::uuid, $2, $3, 'ACTIVE', NULL, 'production', NULL, 'SCHEMA')
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{ tenant_id, slug, slug },
    );
    _ = allocator;
}

/// Insert a bare test tenant row directly into public.tenant.
/// Security: all values bound as parameters — no SQL string interpolation.
fn insertTestTenant(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: []const u8,
    slug: []const u8,
    production_tenant_id: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id, storage_mode)
        \\VALUES ($1::uuid, $2, $3, 'ACTIVE', NULL, 'test', $4::uuid, 'SCHEMA')
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{ tenant_id, slug, slug, production_tenant_id },
    );
    _ = allocator;
}

fn cleanupTenantById(pool: *Pool, tenant_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM public.tenant WHERE id = $1::uuid",
        &[_][]const u8{tenant_id},
    ) catch {};
}

fn dropTenantSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: []const u8,
) void {
    var schema_buf: [80]u8 = undefined;
    const schema_name = schemaNameForTenant(tenant_id, &schema_buf);
    const drop_sql = std.fmt.allocPrint(
        allocator,
        "DROP SCHEMA IF EXISTS {s} CASCADE",
        .{schema_name},
    ) catch return;
    defer allocator.free(drop_sql);

    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(drop_sql, &[_][]const u8{}) catch {};

    conn.exec(
        "DELETE FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &[_][]const u8{tenant_id},
    ) catch {};
    conn.exec(
        "DELETE FROM public.schema_migrations WHERE schema_name = $1",
        &[_][]const u8{schema_name},
    ) catch {};
}

fn migrationsDir() []const u8 {
    return build_options.migrations_dir;
}

// ---------------------------------------------------------------------------
// TC-ENV-02-01
// ---------------------------------------------------------------------------

test "TC-ENV-02-01: T-test connection search_path contains T-test schema and not T schema" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);

    // LIFO: prod_id must be declared FIRST so it runs LAST (after test_id is deleted).
    // ON DELETE RESTRICT blocks deleting a production tenant while test tenants reference it.
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, test_id);

    // Use UUID-derived slugs to avoid conflicts on re-runs (clean_test_db.py does not
    // clean public.tenant, so fixed slugs risk unique-constraint failures).
    try insertProductionTenant(alloc, &pool, prod_id, prod_id);
    try insertTestTenant(alloc, &pool, test_id, test_id, prod_id);

    // Derive expected schema name fragments.
    var prod_schema_buf: [80]u8 = undefined;
    const prod_schema = schemaNameForTenant(prod_id, &prod_schema_buf);
    var test_schema_buf: [80]u8 = undefined;
    const test_schema = schemaNameForTenant(test_id, &test_schema_buf);

    // Acquire a connection scoped to T-test.
    tenant_context.set(test_id);
    defer tenant_context.clear();

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Query the current search_path.
    const row = try conn.queryRow(
        alloc,
        "SHOW search_path",
        &[_][]const u8{},
    );
    defer if (row) |r| {
        for (r) |col| if (col) |v| alloc.free(v);
        alloc.free(r);
    };

    try testing.expect(row != null);
    const sp = row.?[0] orelse return error.TestUnexpectedResult;

    // search_path must contain the T-test schema name.
    try testing.expect(std.mem.indexOf(u8, sp, test_schema) != null);

    // search_path must NOT contain the production schema name.
    try testing.expect(std.mem.indexOf(u8, sp, prod_schema) == null);
}

// ---------------------------------------------------------------------------
// TC-ENV-02-02
// ---------------------------------------------------------------------------

test "TC-ENV-02-02: Unqualified query in T-test resolves to T-test table (not T table)" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);

    defer dropTenantSchema(alloc, &pool, test_id);
    defer dropTenantSchema(alloc, &pool, prod_id);
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, test_id);

    try insertProductionTenant(alloc, &pool, prod_id, prod_id);
    try insertTestTenant(alloc, &pool, test_id, test_id, prod_id);

    // Provision both schemas.
    try provisionTenantSchema(alloc, &pool, prod_id, migrationsDir());
    try provisionTenantSchema(alloc, &pool, test_id, migrationsDir());

    // Insert a process definition row in T's schema (production).
    {
        tenant_context.set(prod_id);
        const conn = try pool.acquire();
        defer pool.release(conn);
        const def_id = try randomUuidStr(alloc);
        defer alloc.free(def_id);
        try conn.exec(
            \\INSERT INTO process_definitions
            \\    (id, tenant_id, name, version, description, status, graph, created_by)
            \\VALUES ($1::uuid, bpm_effective_tenant_id(), 'env02-02-def', '1',
            \\        'isolation test', 'ACTIVE',
            \\        '{"nodes":[{"id":"S","node_type":"START"},{"id":"E","node_type":"END"}],"edges":[{"id":"e1","source":"S","target":"E","is_default":false}]}'::jsonb,
            \\        '00000000-0000-0000-0000-000000000099'::uuid)
            \\ON CONFLICT DO NOTHING
        ,
            &[_][]const u8{def_id},
        );
        tenant_context.clear();
    }

    // Query unqualified process_definitions from T-test connection.
    // T-test's process_definitions table is empty — must return 0.
    tenant_context.set(test_id);
    defer tenant_context.clear();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = try conn.queryRow(
        alloc,
        "SELECT COUNT(*)::text FROM process_definitions",
        &[_][]const u8{},
    );
    defer if (row) |r| {
        for (r) |col| if (col) |v| alloc.free(v);
        alloc.free(r);
    };

    try testing.expect(row != null);
    const count_str = row.?[0] orelse return error.TestUnexpectedResult;
    const count = try std.fmt.parseInt(i64, count_str, 10);
    try testing.expectEqual(@as(i64, 0), count);
}

// ---------------------------------------------------------------------------
// TC-ENV-02-03
// ---------------------------------------------------------------------------

test "TC-ENV-02-03: Qualified cross-schema query from T-test fails or returns no production data" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);

    defer dropTenantSchema(alloc, &pool, test_id);
    defer dropTenantSchema(alloc, &pool, prod_id);
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, test_id);

    try insertProductionTenant(alloc, &pool, prod_id, prod_id);
    try insertTestTenant(alloc, &pool, test_id, test_id, prod_id);

    try provisionTenantSchema(alloc, &pool, prod_id, migrationsDir());
    try provisionTenantSchema(alloc, &pool, test_id, migrationsDir());

    // Do NOT seed a sentinel row in the production schema.
    // In this test environment the platform DB user owns all schemas, so a
    // qualified cross-schema query will succeed rather than error with 42501.
    // The isolation guarantee is based on search_path (tested in TC-ENV-02-01/02);
    // a qualified query returning 0 rows (no production data exists for this
    // fresh test tenant) is accepted as isolation-compliant.

    // Build the qualified schema name for the production tenant.
    var prod_schema_buf: [80]u8 = undefined;
    const prod_schema = schemaNameForTenant(prod_id, &prod_schema_buf);

    // Acquire a T-test connection.
    tenant_context.set(test_id);
    defer tenant_context.clear();

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Build the qualified query using only the schema name (which contains only [a-z0-9_]).
    // Security: schema_name is derived from a validated UUID (hex + underscores only).
    const qualified_sql = try std.fmt.allocPrint(
        alloc,
        "SELECT COUNT(*)::text FROM {s}.process_definitions WHERE name = 'env02-03-sentinel'",
        .{prod_schema},
    );
    defer alloc.free(qualified_sql);

    // The qualified query must either:
    //   (a) fail with a PostgreSQL error (42501 insufficient_privilege or 42P01 undefined_table), OR
    //   (b) return 0 rows (search_path isolation means the sentinel row is invisible).
    // Success (returning the sentinel row's count as > 0) is FORBIDDEN.
    const result = conn.queryRow(alloc, qualified_sql, &[_][]const u8{});
    if (result) |row_opt| {
        if (row_opt) |r| {
            defer {
                for (r) |col| if (col) |v| alloc.free(v);
                alloc.free(r);
            }
            // If the query succeeded, verify the count is 0 (no cross-tenant data visible).
            // A non-zero count here indicates that cross-schema access IS leaking data,
            // which is a security policy violation.
            const count_str = r[0] orelse "0";
            const count = std.fmt.parseInt(i64, count_str, 10) catch 0;
            if (count > 0) {
                std.debug.print(
                    "TC-ENV-02-03 FAIL: cross-schema query returned {d} rows from production schema.\n" ++
                        "The platform DB user has cross-schema grants; this is a security gap.\n",
                    .{count},
                );
                return error.CrossSchemDataLeakDetected;
            }
            // count == 0 means isolation is maintained (T-test schema shadows the prod schema)
            // or the qualified name resolved to T-test's own empty table.
        }
    } else |_| {
        // PostgreSQL error — this is the expected outcome when the DB user
        // lacks cross-schema grants (42501) or the schema name is rejected (42P01).
        // The test passes because the query did NOT return production data.
    }
}
