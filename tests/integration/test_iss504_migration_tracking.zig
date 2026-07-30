//! Integration tests for ISS-504 — Reconcile schema + per-tenant migration
//! tracking (SPT-04).
//!
//! Confirms the migration-state tracking design already implemented by
//! SPT-01 (src/db/migrations.zig, src/db/provisioning.zig) behaves per the
//! decision recorded in src/design/iss504_migration_tracking.md:
//!   - public.schema_migrations is the single source of truth, keyed by
//!     (schema_name, version).
//!   - GBL- migrations are recorded ONLY with schema_name = 'public', never
//!     under a tenant schema.
//!   - Non-GBL (per-tenant) migrations are recorded under schema_name =
//!     'tenant_{slug}', never under schema_name = 'public'.
//!   - Provisioning a new tenant populates its own independent migration
//!     ledger row set, distinct from any other tenant's.
//!
//! Requires a real PostgreSQL database reachable at BPM_TEST_DB_URL.
//! Each test generates a fresh UUID for tenant isolation and cleans up all
//! provisioned artefacts via defer.
//!
//! Requirement traceability:
//!   ISS-504 → TC-ISS504-01 .. TC-ISS504-04
const std = @import("std");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;
const build_options = @import("build_options");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const provisionTenantSchema = bpm.provisioning.provisionTenantSchema;
const schemaNameForTenant = bpm.pool.schemaNameForTenant;

// ---------------------------------------------------------------------------
// Shared helpers (mirrors tests/integration/spt01_provisioning_test.zig)
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) (error{MissingTestDatabaseUrl} || std.mem.Allocator.Error || error{EnvironmentVariableMissing} || error{InvalidWtf8})![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — ISS-504 integration tests FAILED (env var required)\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn migrationsDir() []const u8 {
    return build_options.migrations_dir;
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
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

fn schemaName(uuid_str: []const u8, buf: *[80]u8) []const u8 {
    return schemaNameForTenant(uuid_str, buf);
}

fn cleanupTenant(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id_str: []const u8,
    schema_name_str: []const u8,
) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    const drop_sql = std.fmt.allocPrint(
        allocator,
        "DROP SCHEMA IF EXISTS {s} CASCADE",
        .{schema_name_str},
    ) catch return;
    defer allocator.free(drop_sql);
    conn.exec(drop_sql, &.{}) catch |err| {
        std.debug.print("cleanup: DROP SCHEMA {s} failed: {}\n", .{ schema_name_str, err });
    };

    conn.exec(
        "DELETE FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{tenant_id_str},
    ) catch |err| {
        std.debug.print("cleanup: DELETE tenant_schemas for {s} failed: {}\n", .{ tenant_id_str, err });
    };

    conn.exec(
        "DELETE FROM public.schema_migrations WHERE schema_name = $1",
        &.{schema_name_str},
    ) catch |err| {
        std.debug.print("cleanup: DELETE schema_migrations for {s} failed: {}\n", .{ schema_name_str, err });
    };
}

// ---------------------------------------------------------------------------
// TC-ISS504-01
// GBL- migrations MUST be recorded with schema_name='public' and MUST NEVER
// appear recorded under a tenant schema.
// ---------------------------------------------------------------------------
test "TC-ISS504-01: GBL- migrations recorded only under schema_name='public'" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // At least one GBL- migration must be present under 'public'.
    var public_result = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = 'public' AND version LIKE 'GBL-%'",
        &.{},
    );
    defer public_result.deinit();

    try std.testing.expect(public_result.rows.len > 0);
    const public_count_val = public_result.rows[0][0] orelse return error.TestUnexpectedResult;
    const public_count = try std.fmt.parseInt(i64, public_count_val, 10);
    try std.testing.expect(public_count > 0);

    // No GBL- migration may ever be recorded under a non-public schema_name.
    var non_public_result = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name != 'public' AND version LIKE 'GBL-%'",
        &.{},
    );
    defer non_public_result.deinit();

    try std.testing.expect(non_public_result.rows.len > 0);
    const non_public_count_val = non_public_result.rows[0][0] orelse return error.TestUnexpectedResult;
    const non_public_count = try std.fmt.parseInt(i64, non_public_count_val, 10);
    try std.testing.expectEqual(@as(i64, 0), non_public_count);
}

// ---------------------------------------------------------------------------
// TC-ISS504-02
// Per-tenant (non-GBL) migrations MUST be recorded with
// schema_name='tenant_{slug}' — the tenant schema has its own independent
// ledger rows, keyed to its own schema_name (not merged into or borrowed
// from 'public').
// ---------------------------------------------------------------------------
test "TC-ISS504-02: per-tenant migrations recorded under the tenant's own schema_name" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);

    var schema_buf: [80]u8 = undefined;
    const schema_name_str = schemaName(tenant_id, &schema_buf);

    defer cleanupTenant(alloc, &pool, tenant_id, schema_name_str);

    try provisionTenantSchema(alloc, &pool, tenant_id, migrationsDir());

    // Non-GBL migrations must be recorded under this tenant's own schema_name.
    var tenant_result = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = $1 AND version NOT LIKE 'GBL-%'",
        &.{schema_name_str},
    );
    defer tenant_result.deinit();

    try std.testing.expect(tenant_result.rows.len > 0);
    const tenant_count_val = tenant_result.rows[0][0] orelse return error.TestUnexpectedResult;
    const tenant_count = try std.fmt.parseInt(i64, tenant_count_val, 10);
    try std.testing.expect(tenant_count > 0);

    // No GBL- migration may ever be recorded under this tenant's schema_name
    // (the GBL-prefix guard in runForSchema() must have skipped all of them).
    var gbl_under_tenant = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = $1 AND version LIKE 'GBL-%'",
        &.{schema_name_str},
    );
    defer gbl_under_tenant.deinit();

    const gbl_count_val = gbl_under_tenant.rows[0][0] orelse return error.TestUnexpectedResult;
    const gbl_count = try std.fmt.parseInt(i64, gbl_count_val, 10);
    try std.testing.expectEqual(@as(i64, 0), gbl_count);
}

// ---------------------------------------------------------------------------
// TC-ISS504-03
// Provisioning a new tenant records its per-tenant migration state in its
// own schema, and sets migrations_applied_at in the tenant_schemas registry.
// ---------------------------------------------------------------------------
test "TC-ISS504-03: provisioning records per-tenant migration state and registry timestamp" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);

    var schema_buf: [80]u8 = undefined;
    const schema_name_str = schemaName(tenant_id, &schema_buf);

    defer cleanupTenant(alloc, &pool, tenant_id, schema_name_str);

    try provisionTenantSchema(alloc, &pool, tenant_id, migrationsDir());

    // Migration ledger entries exist for this tenant's schema.
    var migration_result = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = $1",
        &.{schema_name_str},
    );
    defer migration_result.deinit();

    try std.testing.expect(migration_result.rows.len > 0);
    const migration_count_val = migration_result.rows[0][0] orelse return error.TestUnexpectedResult;
    const migration_count = try std.fmt.parseInt(i64, migration_count_val, 10);
    try std.testing.expect(migration_count > 0);

    // tenant_schemas.migrations_applied_at must be set (non-NULL).
    var registry_result = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1::uuid AND migrations_applied_at IS NOT NULL",
        &.{tenant_id},
    );
    defer registry_result.deinit();

    try std.testing.expect(registry_result.rows.len > 0);
    const registry_count_val = registry_result.rows[0][0] orelse return error.TestUnexpectedResult;
    const registry_count = try std.fmt.parseInt(i64, registry_count_val, 10);
    try std.testing.expectEqual(@as(i64, 1), registry_count);
}

// ---------------------------------------------------------------------------
// TC-ISS504-04
// A second tenant provisioned independently has its own migration ledger,
// disjoint from a first tenant's — no cross-tenant leakage of migration
// state (verification point 4 in the design doc, adapted from the ADP-12
// "second tenant has independent migration state" scenario to a targeted
// unit-style integration test, since the full ADP-12 pre/post regression
// suite (tests/integration/adp12_default_tenant_regression_test.zig) already
// separately exercises the default tenant end-to-end under SCHEMA routing).
// ---------------------------------------------------------------------------
test "TC-ISS504-04: independently provisioned tenants have disjoint migration ledgers" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_a = try randomUuidStr(alloc);
    defer alloc.free(tenant_a);
    const tenant_b = try randomUuidStr(alloc);
    defer alloc.free(tenant_b);

    var schema_buf_a: [80]u8 = undefined;
    const schema_a = schemaName(tenant_a, &schema_buf_a);
    var schema_buf_b: [80]u8 = undefined;
    const schema_b = schemaName(tenant_b, &schema_buf_b);

    defer cleanupTenant(alloc, &pool, tenant_a, schema_a);
    defer cleanupTenant(alloc, &pool, tenant_b, schema_b);

    try provisionTenantSchema(alloc, &pool, tenant_a, migrationsDir());
    try provisionTenantSchema(alloc, &pool, tenant_b, migrationsDir());

    // Each tenant's schema_migrations rows are keyed to its own schema_name;
    // no row exists under the other tenant's schema_name.
    var cross_result = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = $1",
        &.{schema_b},
    );
    defer cross_result.deinit();
    try std.testing.expect(cross_result.rows.len > 0);

    var a_result = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = $1",
        &.{schema_a},
    );
    defer a_result.deinit();

    const a_count_val = a_result.rows[0][0] orelse return error.TestUnexpectedResult;
    const a_count = try std.fmt.parseInt(i64, a_count_val, 10);
    const b_count_val = cross_result.rows[0][0] orelse return error.TestUnexpectedResult;
    const b_count = try std.fmt.parseInt(i64, b_count_val, 10);

    try std.testing.expect(a_count > 0);
    try std.testing.expect(b_count > 0);

    // tenant_schemas registry rows are distinct per tenant.
    var registry_result = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.tenant_schemas WHERE tenant_id IN ($1::uuid, $2::uuid) AND migrations_applied_at IS NOT NULL",
        &.{ tenant_a, tenant_b },
    );
    defer registry_result.deinit();

    const registry_count_val = registry_result.rows[0][0] orelse return error.TestUnexpectedResult;
    const registry_count = try std.fmt.parseInt(i64, registry_count_val, 10);
    try std.testing.expectEqual(@as(i64, 2), registry_count);
}
