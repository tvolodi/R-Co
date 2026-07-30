//! Integration tests for ISS-502 — SPT cutover transaction.
//!
//! executeSptCutover() (src/admin/tenant_migration.zig) copies rows from
//! public-schema business tables into a tenant's dedicated schema, verifies
//! row-count parity, then atomically flips tenant.storage_mode from
//! LEGACY_RLS to SCHEMA — all inside a single transaction. Any failure rolls
//! back and leaves the tenant in LEGACY_RLS (safe state). Re-running on an
//! already-SCHEMA tenant is an idempotent no-op.
//!
//! Requires a real PostgreSQL database reachable at BPM_TEST_DB_URL.
//! Every test creates its own fixtures with per-test UUIDs and cleans up via
//! defer (even on failure paths) — no cross-test shared state.
//!
//! NOTE on fixture shape: executeSptCutover() copies rows with
//! `INSERT INTO {tenant_schema}.{table} SELECT * FROM {table} WHERE tenant_id = $1`,
//! so the source (public) and destination (tenant schema) table for a given
//! name must have identical column lists for the copy to succeed. Production
//! per-tenant schema tables (created via provisionTenantSchema/full migration
//! set) carry additional FKs, RLS policies, and audit triggers that are
//! orthogonal to what this unit is responsible for verifying (copy + count
//! parity + atomic flip). This suite therefore hand-creates minimal, schema-
//! matching tables for every entry in SPT_BUSINESS_TABLES directly in both
//! `public` and the tenant schema, rather than calling provisionTenantSchema()
//! (which would apply the full migration set and create incompatible,
//! richer-shaped tables). This keeps the fixtures self-sufficient and focused
//! on the function's actual contract.
//!
//! Requirement traceability:
//!   ISS-502 → TC-ISS502-01 .. TC-ISS502-04

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");
const build_options = @import("build_options");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const schemaNameForTenant = bpm.pool.schemaNameForTenant;
const tenant_migration = bpm.tenant_migration;
const executeSptCutover = tenant_migration.executeSptCutover;
const SptCutoverError = tenant_migration.SptCutoverError;
const CutoverResult = tenant_migration.CutoverResult;

// ---------------------------------------------------------------------------
// The 21 business tables executeSptCutover() iterates over, mirrored from
// SPT_BUSINESS_TABLES in src/admin/tenant_migration.zig. Every one of these
// must exist (even if empty) in both public and the tenant schema, or the
// copy loop fails with CopyFailed on the missing relation.
//
// webhook_deliveries is intentionally excluded — per the TNT-01 design doc
// (src/design/tnt-01-04-schema-isolation.md, 21-table list), it was never
// migrated out of public and is not a TNT-01 business table.
// ---------------------------------------------------------------------------
const SPT_BUSINESS_TABLES = [_][]const u8{
    "process_definitions",
    "instance_projections",
    "events",
    "events_archive",
    "tasks",
    "tokens",
    "timers",
    "audit_entries",
    "audit_log",
    "users",
    "groups",
    "group_members",
    "roles",
    "user_roles",
    "api_tokens",
    "webhook_subscriptions",
    "dead_letter_items",
    "instance_sequence",
    "event_type_registry",
    "event_retention_policies",
    "repository_form_schemas",
};

// A handful of tables get representative (non-empty) rows so row-count
// parity and copy behaviour are genuinely exercised, not just no-op loops.
const POPULATED_TABLES = [_][]const u8{ "process_definitions", "events", "tasks" };

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for ISS-502 integration tests\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
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
            raw[0],  raw[1],  raw[2],  raw[3],
            raw[4],  raw[5],
            raw[6],  raw[7],
            raw[8],  raw[9],
            raw[10], raw[11], raw[12], raw[13], raw[14], raw[15],
        });
}

fn schemaName(uuid_str: []const u8, buf: *[80]u8) []const u8 {
    return schemaNameForTenant(uuid_str, buf);
}

/// Create a tenant row in LEGACY_RLS mode (the column default) with a unique slug.
fn createTenantRow(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id_str: []const u8,
    slug_suffix: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const slug = try std.fmt.allocPrint(allocator, "iss502-{s}", .{slug_suffix[0..8]});
    defer allocator.free(slug);
    const realm = try std.fmt.allocPrint(allocator, "realm-iss502-{s}", .{slug_suffix[0..8]});
    defer allocator.free(realm);

    try conn.exec(
        "INSERT INTO tenant (id, slug, display_name, status, idp_realm_id) VALUES ($1::uuid, $2, 'ISS-502 Test Tenant', 'ACTIVE', $3)",
        &.{ tenant_id_str, slug, realm },
    );
}

/// Create the tenant's schema (empty — no migrations applied) via the same
/// SQL entry point provisionTenantSchema() uses, without pulling in the full
/// per-tenant migration set. Registers a row in tenant_schemas so cleanup and
/// any registry lookups behave consistently with real provisioning.
fn createTenantSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id_str: []const u8,
    schema_name_str: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec("SELECT public.bpm_provision_tenant_schema($1::uuid)", &.{tenant_id_str});
    _ = allocator;
    _ = schema_name_str;
}

/// Hand-create a minimal, column-matching pair of tables (public.<name> and
/// <schema>.<name>) for every entry in SPT_BUSINESS_TABLES. Columns:
///   id uuid primary key default gen_random_uuid()
///   tenant_id uuid not null
///   payload text not null default ''
/// This mirrors just enough shape for INSERT INTO ... SELECT * ... and row
/// count comparisons to exercise the real copy/verify logic, without pulling
/// in production FKs/RLS/triggers that are out of scope for this unit.
fn createBusinessTables(
    allocator: std.mem.Allocator,
    pool: *Pool,
    schema_name_str: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);

    for (SPT_BUSINESS_TABLES) |table_name| {
        const create_public = try std.fmt.allocPrint(
            allocator,
            \\CREATE TABLE IF NOT EXISTS public.{s} (
            \\  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            \\  tenant_id uuid NOT NULL,
            \\  payload text NOT NULL DEFAULT ''
            \\)
        ,
            .{table_name},
        );
        defer allocator.free(create_public);
        try conn.exec(create_public, &.{});

        const create_tenant = try std.fmt.allocPrint(
            allocator,
            \\CREATE TABLE IF NOT EXISTS {s}.{s} (
            \\  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            \\  tenant_id uuid NOT NULL,
            \\  payload text NOT NULL DEFAULT ''
            \\)
        ,
            .{ schema_name_str, table_name },
        );
        defer allocator.free(create_tenant);
        try conn.exec(create_tenant, &.{});
    }

    // executeSptCutover() also copies per-tenant schema_migrations rows. Ensure
    // the table exists in both places (empty is fine — copy is best-effort/non-fatal
    // per the implementation when it fails).
    try conn.exec(
        \\CREATE TABLE IF NOT EXISTS public.schema_migrations (
        \\  version TEXT NOT NULL,
        \\  schema_name TEXT NOT NULL DEFAULT 'public',
        \\  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        \\)
    ,
        &.{},
    );
}

/// Insert `count` representative rows into public.<table> for the given tenant.
fn seedPublicRows(
    allocator: std.mem.Allocator,
    pool: *Pool,
    table_name: []const u8,
    tenant_id_str: []const u8,
    count: usize,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const insert_sql = try std.fmt.allocPrint(
        allocator,
        "INSERT INTO public.{s} (tenant_id, payload) VALUES ($1::uuid, $2)",
        .{table_name},
    );
    defer allocator.free(insert_sql);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const payload = try std.fmt.allocPrint(allocator, "row-{d}", .{i});
        defer allocator.free(payload);
        try conn.exec(insert_sql, &.{ tenant_id_str, payload });
    }
}

/// Count rows in a table (public.<table> or <schema>.<table>) scoped by
/// tenant_id where relevant. schema_prefix "" means unqualified/public.
fn countRows(
    allocator: std.mem.Allocator,
    pool: *Pool,
    qualified_table: []const u8,
) !usize {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const sql = try std.fmt.allocPrint(allocator, "SELECT count(*) FROM {s}", .{qualified_table});
    defer allocator.free(sql);

    const row = try conn.queryRow(allocator, sql, &.{});
    if (row) |r| {
        defer {
            if (r[0]) |v| allocator.free(v);
            allocator.free(r);
        }
        if (r[0]) |count_str| {
            return std.fmt.parseInt(usize, count_str, 10) catch 0;
        }
    }
    return 0;
}

fn getStorageMode(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id_str: []const u8,
) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = try conn.queryRow(
        allocator,
        "SELECT storage_mode FROM tenant WHERE id = $1::uuid",
        &.{tenant_id_str},
    );
    if (row) |r| {
        defer allocator.free(r);
        if (r[0]) |mode| return mode; // caller owns
        return allocator.dupe(u8, "");
    }
    return allocator.dupe(u8, "");
}

/// Drop the tenant schema, the hand-created public.<table> fixtures for this
/// test, the tenant row, and its tenant_schemas registration. Best-effort —
/// errors are printed but not propagated (used in defer, must survive partial
/// setup / mid-test failures).
fn cleanupTenant(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id_str: []const u8,
    schema_name_str: []const u8,
) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    for (SPT_BUSINESS_TABLES) |table_name| {
        const drop_public = std.fmt.allocPrint(
            allocator,
            "DROP TABLE IF EXISTS public.{s} CASCADE",
            .{table_name},
        ) catch continue;
        defer allocator.free(drop_public);
        conn.exec(drop_public, &.{}) catch |err| {
            std.debug.print("cleanup: DROP TABLE public.{s} failed: {}\n", .{ table_name, err });
        };
    }

    const drop_schema = std.fmt.allocPrint(
        allocator,
        "DROP SCHEMA IF EXISTS {s} CASCADE",
        .{schema_name_str},
    ) catch return;
    defer allocator.free(drop_schema);
    conn.exec(drop_schema, &.{}) catch |err| {
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

    conn.exec(
        "DELETE FROM public.tenant WHERE id = $1::uuid",
        &.{tenant_id_str},
    ) catch |err| {
        std.debug.print("cleanup: DELETE tenant {s} failed: {}\n", .{ tenant_id_str, err });
    };
}

/// Full fixture setup shared by all four test cases: tenant row (LEGACY_RLS),
/// tenant schema, matching business tables in both public and the tenant
/// schema, and representative rows in POPULATED_TABLES.
fn setupFixture(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id_str: []const u8,
    schema_name_str: []const u8,
) !void {
    try createTenantRow(allocator, pool, tenant_id_str, tenant_id_str);
    try createTenantSchema(allocator, pool, tenant_id_str, schema_name_str);
    try createBusinessTables(allocator, pool, schema_name_str);

    for (POPULATED_TABLES) |table_name| {
        try seedPublicRows(allocator, pool, table_name, tenant_id_str, 3);
    }
}

// ---------------------------------------------------------------------------
// TC-ISS502-01: cutover copies all rows and flips storage_mode to SCHEMA
// ---------------------------------------------------------------------------

test "TC-ISS502-01: cutover copies all rows and flips storage_mode to SCHEMA" {
    const alloc = testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
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

    try setupFixture(alloc, &pool, tenant_id, schema_name_str);

    // Count rows in public business tables for this tenant before cutover.
    var expected_total: usize = 0;
    for (POPULATED_TABLES) |table_name| {
        const qualified = try std.fmt.allocPrint(alloc, "public.{s}", .{table_name});
        defer alloc.free(qualified);
        expected_total += try countRows(alloc, &pool, qualified);
    }
    try testing.expect(expected_total == POPULATED_TABLES.len * 3);

    // Verify precondition: storage_mode starts as LEGACY_RLS.
    const mode_before = try getStorageMode(alloc, &pool, tenant_id);
    defer alloc.free(mode_before);
    try testing.expectEqualStrings("LEGACY_RLS", mode_before);

    const result = try executeSptCutover(alloc, &pool, tenant_id, schema_name_str);

    try testing.expect(!result.already_migrated);
    try testing.expectEqual(SPT_BUSINESS_TABLES.len, result.tables_verified);
    try testing.expectEqual(expected_total, result.rows_copied);

    // Verify storage_mode is now SCHEMA.
    const mode_after = try getStorageMode(alloc, &pool, tenant_id);
    defer alloc.free(mode_after);
    try testing.expectEqualStrings("SCHEMA", mode_after);

    // Verify row counts in the tenant schema match the original public counts.
    for (POPULATED_TABLES) |table_name| {
        const qualified = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ schema_name_str, table_name });
        defer alloc.free(qualified);
        const schema_count = try countRows(alloc, &pool, qualified);
        try testing.expectEqual(@as(usize, 3), schema_count);
    }
}

// ---------------------------------------------------------------------------
// TC-ISS502-02: cutover is idempotent (re-run is a no-op)
// ---------------------------------------------------------------------------

test "TC-ISS502-02: cutover is idempotent on an already-SCHEMA tenant" {
    const alloc = testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
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

    try setupFixture(alloc, &pool, tenant_id, schema_name_str);

    // First cutover — brings the tenant to SCHEMA mode.
    const first = try executeSptCutover(alloc, &pool, tenant_id, schema_name_str);
    try testing.expect(!first.already_migrated);

    // Snapshot tenant-schema row counts after the first cutover.
    var counts_after_first = std.ArrayList(usize).empty;
    defer counts_after_first.deinit(alloc);
    for (SPT_BUSINESS_TABLES) |table_name| {
        const qualified = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ schema_name_str, table_name });
        defer alloc.free(qualified);
        try counts_after_first.append(alloc, try countRows(alloc, &pool, qualified));
    }

    // Second cutover on the now-SCHEMA tenant — must be a no-op.
    const second = try executeSptCutover(alloc, &pool, tenant_id, schema_name_str);

    try testing.expect(second.already_migrated);
    try testing.expectEqual(@as(usize, 0), second.rows_copied);
    try testing.expectEqual(@as(usize, 0), second.tables_verified);

    // Row counts in the tenant schema must be unchanged (nothing re-copied).
    for (SPT_BUSINESS_TABLES, 0..) |table_name, idx| {
        const qualified = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ schema_name_str, table_name });
        defer alloc.free(qualified);
        const count_now = try countRows(alloc, &pool, qualified);
        try testing.expectEqual(counts_after_first.items[idx], count_now);
    }

    // storage_mode remains SCHEMA.
    const mode = try getStorageMode(alloc, &pool, tenant_id);
    defer alloc.free(mode);
    try testing.expectEqualStrings("SCHEMA", mode);
}

// ---------------------------------------------------------------------------
// TC-ISS502-03: failure rolls back, leaving the tenant in LEGACY_RLS
// ---------------------------------------------------------------------------

test "TC-ISS502-03: PK conflict in tenant schema rolls back and keeps LEGACY_RLS" {
    const alloc = testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
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

    try setupFixture(alloc, &pool, tenant_id, schema_name_str);

    // Inject a PK conflict: copy one public.process_definitions row's id into
    // the tenant schema ahead of time, so the INSERT ... SELECT * during
    // cutover collides on the primary key.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        const src_row = try conn.queryRow(
            alloc,
            "SELECT id, tenant_id, payload FROM public.process_definitions WHERE tenant_id = $1::uuid LIMIT 1",
            &.{tenant_id},
        );
        try testing.expect(src_row != null);
        const row = src_row.?;
        defer {
            for (row) |col| {
                if (col) |c| alloc.free(c);
            }
            alloc.free(row);
        }
        const conflicting_id = row[0].?;
        const conflicting_tenant = row[1].?;
        const conflicting_payload = row[2].?;

        const insert_conflict_sql = try std.fmt.allocPrint(
            alloc,
            "INSERT INTO {s}.process_definitions (id, tenant_id, payload) VALUES ($1::uuid, $2::uuid, $3)",
            .{schema_name_str},
        );
        defer alloc.free(insert_conflict_sql);
        try conn.exec(insert_conflict_sql, &.{ conflicting_id, conflicting_tenant, conflicting_payload });
    }

    // Cutover must fail with CopyFailed because of the PK conflict.
    const result = executeSptCutover(alloc, &pool, tenant_id, schema_name_str);
    try testing.expectError(SptCutoverError.CopyFailed, result);

    // storage_mode must still be LEGACY_RLS — the transaction rolled back.
    const mode = try getStorageMode(alloc, &pool, tenant_id);
    defer alloc.free(mode);
    try testing.expectEqualStrings("LEGACY_RLS", mode);
}

// ---------------------------------------------------------------------------
// TC-ISS502-04: row count mismatch is detected
// ---------------------------------------------------------------------------

test "TC-ISS502-04: row count mismatch after copy is detected as RowCountMismatch" {
    const alloc = testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
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

    try setupFixture(alloc, &pool, tenant_id, schema_name_str);

    // Insert an extra row directly into the tenant schema for a table with
    // zero rows seeded in public (a table from SPT_BUSINESS_TABLES that is
    // NOT in POPULATED_TABLES). After the (successful, zero-row) copy step
    // for that table, the destination still has one pre-existing row while
    // public has zero: counts diverge and step 4 (verify row count parity)
    // must detect the mismatch.
    const mismatch_table = "roles"; // not in POPULATED_TABLES -> zero rows in public
    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        const insert_sql = try std.fmt.allocPrint(
            alloc,
            "INSERT INTO {s}.{s} (tenant_id, payload) VALUES ($1::uuid, 'pre-existing')",
            .{ schema_name_str, mismatch_table },
        );
        defer alloc.free(insert_sql);
        try conn.exec(insert_sql, &.{tenant_id});
    }

    const result = executeSptCutover(alloc, &pool, tenant_id, schema_name_str);
    try testing.expectError(SptCutoverError.RowCountMismatch, result);

    // storage_mode must still be LEGACY_RLS — the transaction rolled back.
    const mode = try getStorageMode(alloc, &pool, tenant_id);
    defer alloc.free(mode);
    try testing.expectEqualStrings("LEGACY_RLS", mode);
}
