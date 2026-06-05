//! Integration tests for SPT-01 — Schema-per-tenant provisioning infrastructure.
//!
//! Covers: provisionTenantSchema, runForSchema, schemaNameForTenant,
//! applyRequestTenantContext (search_path), public.tenant_schemas registry,
//! and public.schema_migrations per-schema tracking.
//!
//! Requires a real PostgreSQL database reachable at BPM_TEST_DB_URL.
//! Each test generates a fresh UUID for complete tenant isolation and
//! cleans up all provisioned artefacts (DROP SCHEMA … CASCADE + DELETE
//! FROM public.tenant_schemas + DELETE FROM public.schema_migrations) via defer.
//!
//! Requirement traceability:
//!   SPT-01 → TC-SPT-01-01 .. TC-SPT-01-08
const std = @import("std");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;
const build_options = @import("build_options");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const provisionTenantSchema = bpm.provisioning.provisionTenantSchema;
const schemaNameForTenant = bpm.pool.schemaNameForTenant;
const tenant_context = bpm.api_tenant_context;

// Root context — kept for legacy @hasDecl guards in other tests, but SPT-01
// search_path tests use tenant_context directly to avoid test_runner root issues.
const root = @import("root");

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Read BPM_TEST_DB_URL from the environment.
/// Returns error.MissingTestDatabaseUrl when the variable is absent so that
/// the test fails clearly with a named error (not a silent skip).
fn testDbUrl(allocator: std.mem.Allocator) (error{MissingTestDatabaseUrl} || std.mem.Allocator.Error || error{EnvironmentVariableMissing} || error{InvalidWtf8})![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — SPT-01 integration tests FAILED (env var required)\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

/// Return the migrations directory path from build options.
fn migrationsDir() []const u8 {
    return build_options.migrations_dir;
}

/// Create a fresh pool pointing at the test database.
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

/// Generate a simple hex UUID string from random bytes.
/// The result is formatted as xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx and
/// owned by the caller (must be freed with allocator.free).
fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    // Set version 4 and variant bits per RFC 4122.
    raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant 10xx
    return std.fmt.allocPrint(allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            raw[0], raw[1], raw[2],  raw[3],
            raw[4], raw[5],
            raw[6], raw[7],
            raw[8], raw[9],
            raw[10], raw[11], raw[12], raw[13], raw[14], raw[15],
        });
}

/// Derive schema name from a UUID string using the same logic as schemaNameForTenant.
/// Returns a stack buffer — caller must use the result immediately.
fn schemaName(uuid_str: []const u8, buf: *[80]u8) []const u8 {
    return schemaNameForTenant(uuid_str, buf);
}

/// Clean up a provisioned test tenant schema plus all related tracking rows.
/// Best-effort: errors are printed but not propagated (used in defer).
fn cleanupTenant(
    allocator: std.mem.Allocator,
    pool: *Pool,
    scope_id_str: []const u8,
    schema_name_str: []const u8,
) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    // Drop schema and all objects within it.
    const drop_sql = std.fmt.allocPrint(
        allocator,
        "DROP SCHEMA IF EXISTS {s} CASCADE",
        .{schema_name_str},
    ) catch return;
    defer allocator.free(drop_sql);
    conn.exec(drop_sql, &.{}) catch |err| {
        std.debug.print("cleanup: DROP SCHEMA {s} failed: {}\n", .{ schema_name_str, err });
    };

    // Remove registry row.
    conn.exec(
        "DELETE FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{scope_id_str},
    ) catch |err| {
        std.debug.print("cleanup: DELETE schema for {s} failed: {}\n", .{ scope_id_str, err });
    };

    // Remove schema_migrations rows for this schema.
    conn.exec(
        "DELETE FROM public.schema_migrations WHERE schema_name = $1",
        &.{schema_name_str},
    ) catch |err| {
        std.debug.print("cleanup: DELETE schema_migrations for {s} failed: {}\n", .{ schema_name_str, err });
    };
}

// ---------------------------------------------------------------------------
// TC-SPT-01-01
// Verify that provisionTenantSchema creates a PostgreSQL schema named
// "tenant_<uuid_no_hyphens>" for a fresh UUID.
// ---------------------------------------------------------------------------
test "TC-SPT-01-01: provisionTenantSchema creates schema named tenant_<uuid_no_hyphens>" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const schema_owner = try randomUuidStr(alloc);
    defer alloc.free(schema_owner);

    var schema_buf: [80]u8 = undefined;
    const schema_name_str = schemaName(schema_owner, &schema_buf);

    // Ensure cleanup even if the test fails mid-way.
    defer cleanupTenant(alloc, &pool, schema_owner, schema_name_str);

    try provisionTenantSchema(alloc, &pool, schema_owner, migrationsDir());

    // Query information_schema.schemata to verify the schema was created.
    const conn = try pool.acquire();
    defer pool.release(conn);

    var result = try conn.query(
        alloc,
        "SELECT count(*) FROM information_schema.schemata WHERE schema_name = $1",
        &.{schema_name_str},
    );
    defer result.deinit();

    try std.testing.expect(result.rows.len > 0);
    const count_val = result.rows[0][0] orelse return error.TestUnexpectedResult;
    const count = try std.fmt.parseInt(i64, count_val, 10);
    try std.testing.expectEqual(@as(i64, 1), count);
}

// ---------------------------------------------------------------------------
// TC-SPT-01-02
// Verify that provisionTenantSchema is idempotent: calling it twice with the
// same UUID does not error and produces exactly one row in tenant_schemas.
// ---------------------------------------------------------------------------
test "TC-SPT-01-02: provisionTenantSchema is idempotent" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const schema_owner = try randomUuidStr(alloc);
    defer alloc.free(schema_owner);

    var schema_buf: [80]u8 = undefined;
    const schema_name_str = schemaName(schema_owner, &schema_buf);

    defer cleanupTenant(alloc, &pool, schema_owner, schema_name_str);

    // First call — should provision.
    try provisionTenantSchema(alloc, &pool, schema_owner, migrationsDir());

    // Second call — should be a silent no-op.
    try provisionTenantSchema(alloc, &pool, schema_owner, migrationsDir());

    // Exactly one row must exist in public.tenant_schemas.
    const conn = try pool.acquire();
    defer pool.release(conn);

    var result = try conn.query(
        alloc,
        "SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{schema_owner},
    );
    defer result.deinit();

    try std.testing.expect(result.rows.len > 0);
    const count_val = result.rows[0][0] orelse return error.TestUnexpectedResult;
    const count = try std.fmt.parseInt(i64, count_val, 10);
    try std.testing.expectEqual(@as(i64, 1), count);
}

// ---------------------------------------------------------------------------
// TC-SPT-01-03
// Verify that runForSchema applied migrations inside the new tenant schema:
// pg_tables must list key tables (events, process_definitions, tasks) under
// the provisioned schema name.
// ---------------------------------------------------------------------------
test "TC-SPT-01-03: runForSchema applies migrations inside the new schema" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const schema_owner = try randomUuidStr(alloc);
    defer alloc.free(schema_owner);

    var schema_buf: [80]u8 = undefined;
    const schema_name_str = schemaName(schema_owner, &schema_buf);

    defer cleanupTenant(alloc, &pool, schema_owner, schema_name_str);

    try provisionTenantSchema(alloc, &pool, schema_owner, migrationsDir());

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Check that the three key tables exist in the tenant schema.
    var result = try conn.query(
        alloc,
        \\SELECT count(*) FROM pg_tables
        \\WHERE schemaname = $1
        \\  AND tablename IN ('events', 'process_definitions', 'tasks')
    ,
        &.{schema_name_str},
    );
    defer result.deinit();

    try std.testing.expect(result.rows.len > 0);
    const count_val = result.rows[0][0] orelse return error.TestUnexpectedResult;
    const count = try std.fmt.parseInt(i64, count_val, 10);
    // All three tables must have been created inside the tenant schema.
    try std.testing.expectEqual(@as(i64, 3), count);
}

// ---------------------------------------------------------------------------
// TC-SPT-01-04
// Verify that public.schema_migrations records (schema_name, version) for
// each migration applied to the tenant schema.
// ---------------------------------------------------------------------------
test "TC-SPT-01-04: schema_migrations records (schema_name, version) per applied migration" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const schema_owner = try randomUuidStr(alloc);
    defer alloc.free(schema_owner);

    var schema_buf: [80]u8 = undefined;
    const schema_name_str = schemaName(schema_owner, &schema_buf);

    defer cleanupTenant(alloc, &pool, schema_owner, schema_name_str);

    try provisionTenantSchema(alloc, &pool, schema_owner, migrationsDir());

    const conn = try pool.acquire();
    defer pool.release(conn);

    var result = try conn.query(
        alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = $1",
        &.{schema_name_str},
    );
    defer result.deinit();

    try std.testing.expect(result.rows.len > 0);
    const count_val = result.rows[0][0] orelse return error.TestUnexpectedResult;
    const count = try std.fmt.parseInt(i64, count_val, 10);
    // At least one migration version must be recorded for the tenant schema.
    try std.testing.expect(count > 0);
}

// ---------------------------------------------------------------------------
// TC-SPT-01-05
// Verify that the default UUID (00000000-...) maps to schema name
// "tenant_default", and that the schema + tenant_schemas row are created.
// ---------------------------------------------------------------------------
test "TC-SPT-01-05: default UUID maps to schema name tenant_default" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const default_uuid = "00000000-0000-0000-0000-000000000000";

    // Ensure cleanup of tenant_default schema and tracking rows even if the test fails.
    defer cleanupTenant(alloc, &pool, default_uuid, "tenant_default");

    // Attempt provisioning; may already be provisioned from a prior test run.
    // provisionTenantSchema is idempotent so this is always safe.
    provisionTenantSchema(alloc, &pool, default_uuid, migrationsDir()) catch |err| {
        // If already provisioned the idempotency guard returns immediately (no error).
        // Any other error is propagated.
        return err;
    };

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Verify tenant_schemas row has schema_name = 'tenant_default'.
    var reg_result = try conn.query(
        alloc,
        "SELECT schema_name FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{default_uuid},
    );
    defer reg_result.deinit();

    try std.testing.expect(reg_result.rows.len > 0);
    const stored_name = reg_result.rows[0][0] orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("tenant_default", stored_name);

    // Verify the schema itself exists.
    var schema_result = try conn.query(
        alloc,
        "SELECT count(*) FROM information_schema.schemata WHERE schema_name = 'tenant_default'",
        &.{},
    );
    defer schema_result.deinit();

    try std.testing.expect(schema_result.rows.len > 0);
    const count_val = schema_result.rows[0][0] orelse return error.TestUnexpectedResult;
    const count = try std.fmt.parseInt(i64, count_val, 10);
    try std.testing.expectEqual(@as(i64, 1), count);
}

// ---------------------------------------------------------------------------
// TC-SPT-01-06
// Verify that a pool connection checkout sets search_path to
// '<tenant_schema>,public' for a non-default tenant.
//
// We set the api_tenant_context to a test UUID, acquire a connection (which
// calls applyRequestTenantContext internally), and issue SHOW search_path.
// ---------------------------------------------------------------------------
test "TC-SPT-01-06: pool checkout sets search_path to tenant schema for non-default tenant" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Use a fixed UUID to keep the test deterministic — no provisioning needed
    // for this test since we are only verifying the search_path setting, not
    // that the schema actually exists.
    const test_uuid = "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5";

    var schema_buf: [80]u8 = undefined;
    const expected_schema = schemaName(test_uuid, &schema_buf);

    // Set the pool-level tenant context so that applyRequestTenantContext reads it.
    // Use tenant_context directly (not root, which resolves to test_runner in unit tests).
    tenant_context.set(test_uuid);
    defer tenant_context.set("00000000-0000-0000-0000-000000000000");

    const conn = try pool.acquire();
    defer pool.release(conn);

    var sp_result = try conn.query(alloc, "SHOW search_path", &.{});
    defer sp_result.deinit();

    try std.testing.expect(sp_result.rows.len > 0);
    const sp_val = sp_result.rows[0][0] orelse return error.TestUnexpectedResult;

    // The search_path must contain the expected tenant schema name.
    const found = std.mem.indexOf(u8, sp_val, expected_schema) != null;
    if (!found) {
        std.debug.print(
            "TC-SPT-01-06: expected search_path to contain '{s}', got: '{s}'\n",
            .{ expected_schema, sp_val },
        );
    }
    try std.testing.expect(found);
}

// ---------------------------------------------------------------------------
// TC-SPT-01-07
// Verify that a pool connection checkout sets search_path to
// 'tenant_default,public' when the tenant context is empty (default tenant).
// ---------------------------------------------------------------------------
test "TC-SPT-01-07: pool checkout for default tenant sets search_path to tenant_default" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Empty string is the "no tenant / default tenant" signal.
    // Use tenant_context directly (not root, which resolves to test_runner in unit tests).
    tenant_context.set("");
    defer tenant_context.set("00000000-0000-0000-0000-000000000000");

    const conn = try pool.acquire();
    defer pool.release(conn);

    var sp_result = try conn.query(alloc, "SHOW search_path", &.{});
    defer sp_result.deinit();

    try std.testing.expect(sp_result.rows.len > 0);
    const sp_val = sp_result.rows[0][0] orelse return error.TestUnexpectedResult;

    const found = std.mem.indexOf(u8, sp_val, "tenant_default") != null;
    if (!found) {
        std.debug.print(
            "TC-SPT-01-07: expected search_path to contain 'tenant_default', got: '{s}'\n",
            .{sp_val},
        );
    }
    try std.testing.expect(found);
}

// ---------------------------------------------------------------------------
// TC-SPT-01-08
// Verify that existing public-schema migrations (001 through 059) are tracked
// in public.schema_migrations with schema_name = 'public' after migration 060
// adds the schema_name column with DEFAULT 'public'.
// ---------------------------------------------------------------------------
test "TC-SPT-01-08: existing migrations tracked with schema_name='public' after migration 060" {
    const alloc = std.testing.allocator;

    // TestHarness.init() applies all migrations including 060, which back-fills
    // schema_name = 'public' (via DEFAULT 'public' on the new column) for all
    // previously applied public-schema migration rows.
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // Query for migration 001 with schema_name = 'public'.
    var result = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = 'public' AND version LIKE '001%'",
        &.{},
    );
    defer result.deinit();

    try std.testing.expect(result.rows.len > 0);
    const count_val = result.rows[0][0] orelse return error.TestUnexpectedResult;
    const count = try std.fmt.parseInt(i64, count_val, 10);
    // Migration 001 must be present and attributed to schema 'public'.
    try std.testing.expect(count > 0);
}
