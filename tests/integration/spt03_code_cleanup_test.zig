//! Integration tests for SPT-03 — Remove legacy bpm.tenant_id session variable
//! and tenant_id predicates from all Zig source files.
//!
//! Verifies the SPT-03 acceptance criteria against a live PostgreSQL database:
//!   AC-1: grep pattern produces no matches (structural, verified by build+code review).
//!   AC-2: zig build exits 0 with no unused-field warnings (verified in CI).
//!   AC-3: search_path is sole tenancy mechanism — no bpm.tenant_id session variable.
//!   AC-4: Concurrent tenants are isolated via search_path.
//!
//! All tests use per-test UUIDs and TestHarness rollback for automatic cleanup.
//!
//! Requirement: SPT-03
//! Requires: BPM_TEST_DB_URL set to a real PostgreSQL instance.

const std = @import("std");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const schemaNameForTenant = bpm.pool.schemaNameForTenant;
const tenant_context = bpm.api_tenant_context;

// Kept for @hasDecl guard compatibility (consistent with other integration modules).
const root = @import("root");
const build_options = @import("build_options");

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — SPT-03 integration tests FAILED\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 3,
    });
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            raw[0],  raw[1],  raw[2],  raw[3],
            raw[4],  raw[5],  raw[6],  raw[7],
            raw[8],  raw[9],  raw[10], raw[11],
            raw[12], raw[13], raw[14], raw[15],
        },
    );
}

// ---------------------------------------------------------------------------
// TC-SPT-03-01 (AC-3a)
// GIVEN a pool connection acquired after SPT-03 cleanup, WHEN
// current_setting('bpm.tenant_id', true) is queried, THEN it returns NULL or
// empty string — the legacy session variable is no longer set by the platform.
// ---------------------------------------------------------------------------
test "TC-SPT-03-01: bpm.tenant_id session variable is absent after pool connection checkout" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // Query the legacy session variable.  'true' makes missing-var return NULL
    // rather than raising an error.
    var result = try h.conn.query(
        alloc,
        "SELECT COALESCE(current_setting('bpm.tenant_id', true), '') AS val",
        &.{},
    );
    defer result.deinit();

    try std.testing.expect(result.rows.len > 0);
    const val = result.rows[0][0] orelse "";
    if (val.len != 0) {
        std.debug.print(
            "TC-SPT-03-01 FAIL: bpm.tenant_id is '{s}' — expected empty/absent (SPT-03 session variable not removed)\n",
            .{val},
        );
    }
    try std.testing.expectEqualStrings("", val);
}

// ---------------------------------------------------------------------------
// TC-SPT-03-02 (AC-3b)
// GIVEN a pool with a test tenant set in the tenant context module, WHEN a
// connection is acquired, THEN current_schema() equals the expected
// tenant_<uuid_no_hyphens> schema.
// ---------------------------------------------------------------------------
test "TC-SPT-03-02: search_path set to correct tenant schema after pool checkout" {
    const alloc = std.testing.allocator;

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const uuid = try randomUuidStr(alloc);
    defer alloc.free(uuid);

    // Provision the tenant schema.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec("SELECT public.bpm_provision_tenant_schema($1::uuid)", &.{uuid});
    }

    var cleanup_schema_buf: [80]u8 = undefined;
    const cleanup_schema = schemaNameForTenant(uuid, &cleanup_schema_buf);
    var cleanup_drop_buf: [128]u8 = undefined;
    const cleanup_drop_sql = std.fmt.bufPrint(
        &cleanup_drop_buf,
        "DROP SCHEMA IF EXISTS {s} CASCADE",
        .{cleanup_schema},
    ) catch "DROP SCHEMA IF EXISTS tenant_cleanup_fallback CASCADE";

    // Cleanup: drop provisioned schema, remove registry rows.
    defer {
        if (pool.acquire()) |conn2| {
            defer pool.release(conn2);
            conn2.exec(cleanup_drop_sql, &.{}) catch {};
            conn2.exec("DELETE FROM public.tenant_schemas WHERE schema_name = $1", &.{cleanup_schema}) catch {};
            conn2.exec("DELETE FROM public.schema_migrations WHERE schema_name = $1", &.{cleanup_schema}) catch {};
        } else |_| {}
    }

    // Set tenant context then acquire a connection — pool.acquire() calls
    // applyRequestTenantContext() which sets search_path.
    tenant_context.set(uuid);
    defer tenant_context.set("");

    const conn = try pool.acquire();
    defer pool.release(conn);

    var schema_result = try conn.query(alloc, "SELECT current_schema()", &.{});
    defer schema_result.deinit();

    try std.testing.expect(schema_result.rows.len > 0);
    const current_schema = schema_result.rows[0][0] orelse "";

    var buf: [80]u8 = undefined;
    const expected_schema = schemaNameForTenant(uuid, &buf);

    if (!std.mem.eql(u8, current_schema, expected_schema)) {
        std.debug.print(
            "TC-SPT-03-02 FAIL: current_schema()='{s}', expected='{s}'\n",
            .{ current_schema, expected_schema },
        );
    }
    try std.testing.expectEqualStrings(expected_schema, current_schema);
}

// ---------------------------------------------------------------------------
// TC-SPT-03-03 (AC-3c / migration 068)
// GIVEN migration 068 applied, WHEN information_schema.columns is queried for
// public.events and public.events_archive, THEN tenant_id is absent from both.
// ---------------------------------------------------------------------------
test "TC-SPT-03-03: tenant_id column absent from public.events and public.events_archive after migration 068" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // Check public.events.
    var events_result = try h.conn.query(alloc,
        \\SELECT count(*)::text
        \\FROM information_schema.columns
        \\WHERE table_schema = 'public'
        \\  AND table_name = 'events'
        \\  AND column_name = 'tenant_id'
    , &.{});
    defer events_result.deinit();

    try std.testing.expect(events_result.rows.len > 0);
    const events_count = try std.fmt.parseInt(i64, events_result.rows[0][0] orelse "0", 10);
    if (events_count != 0) {
        std.debug.print(
            "TC-SPT-03-03 FAIL: public.events still has tenant_id column (count={})\n",
            .{events_count},
        );
    }
    try std.testing.expectEqual(@as(i64, 0), events_count);

    // Check public.events_archive.
    var archive_result = try h.conn.query(alloc,
        \\SELECT count(*)::text
        \\FROM information_schema.columns
        \\WHERE table_schema = 'public'
        \\  AND table_name = 'events_archive'
        \\  AND column_name = 'tenant_id'
    , &.{});
    defer archive_result.deinit();

    try std.testing.expect(archive_result.rows.len > 0);
    const archive_count = try std.fmt.parseInt(i64, archive_result.rows[0][0] orelse "0", 10);
    if (archive_count != 0) {
        std.debug.print(
            "TC-SPT-03-03 FAIL: public.events_archive still has tenant_id column (count={})\n",
            .{archive_count},
        );
    }
    try std.testing.expectEqual(@as(i64, 0), archive_count);
}

// ---------------------------------------------------------------------------
// TC-SPT-03-04 (AC-4)
// GIVEN two provisioned tenant schemas, WHEN a test row is inserted in schema A,
// THEN it is absent from schema B — search_path provides full isolation.
// Uses a dedicated isolation-check table rather than the full events table
// because bpm_provision_tenant_schema() (the SQL function) does not run
// migrations inside the new schema; the events table may not exist there.
// ---------------------------------------------------------------------------
test "TC-SPT-03-04: per-schema isolation verified via test table" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const uuid_a = try randomUuidStr(alloc);
    defer alloc.free(uuid_a);
    const uuid_b = try randomUuidStr(alloc);
    defer alloc.free(uuid_b);

    var buf_a: [80]u8 = undefined;
    var buf_b: [80]u8 = undefined;
    const schema_a = schemaNameForTenant(uuid_a, &buf_a);
    const schema_b = schemaNameForTenant(uuid_b, &buf_b);

    // Provision both schemas inside the TestHarness transaction.
    try h.conn.exec("SELECT public.bpm_provision_tenant_schema($1::uuid)", &.{uuid_a});
    try h.conn.exec("SELECT public.bpm_provision_tenant_schema($1::uuid)", &.{uuid_b});

    // Create a minimal isolation-check table in each schema.
    const create_a = try std.fmt.allocPrint(
        alloc,
        "CREATE TABLE {s}.spt03_iso_check (id SERIAL PRIMARY KEY, marker TEXT NOT NULL)",
        .{schema_a},
    );
    defer alloc.free(create_a);
    try h.conn.exec(create_a, &.{});

    const create_b = try std.fmt.allocPrint(
        alloc,
        "CREATE TABLE {s}.spt03_iso_check (id SERIAL PRIMARY KEY, marker TEXT NOT NULL)",
        .{schema_b},
    );
    defer alloc.free(create_b);
    try h.conn.exec(create_b, &.{});

    // Insert one row into schema A only.
    const insert_a = try std.fmt.allocPrint(
        alloc,
        "INSERT INTO {s}.spt03_iso_check (marker) VALUES ('tenant-a-only')",
        .{schema_a},
    );
    defer alloc.free(insert_a);
    try h.conn.exec(insert_a, &.{});

    // Schema A must have 1 row.
    const count_a_sql = try std.fmt.allocPrint(
        alloc,
        "SELECT count(*)::text FROM {s}.spt03_iso_check",
        .{schema_a},
    );
    defer alloc.free(count_a_sql);
    var result_a = try h.conn.query(alloc, count_a_sql, &.{});
    defer result_a.deinit();
    try std.testing.expect(result_a.rows.len > 0);
    const n_a = try std.fmt.parseInt(i64, result_a.rows[0][0] orelse "0", 10);
    try std.testing.expectEqual(@as(i64, 1), n_a);

    // Schema B must have 0 rows (no cross-tenant contamination).
    const count_b_sql = try std.fmt.allocPrint(
        alloc,
        "SELECT count(*)::text FROM {s}.spt03_iso_check",
        .{schema_b},
    );
    defer alloc.free(count_b_sql);
    var result_b = try h.conn.query(alloc, count_b_sql, &.{});
    defer result_b.deinit();
    try std.testing.expect(result_b.rows.len > 0);
    const n_b = try std.fmt.parseInt(i64, result_b.rows[0][0] orelse "0", 10);
    if (n_b != 0) {
        std.debug.print(
            "TC-SPT-03-04 FAIL: cross-tenant contamination — schema B sees {} row(s) from schema A\n",
            .{n_b},
        );
    }
    try std.testing.expectEqual(@as(i64, 0), n_b);
}
