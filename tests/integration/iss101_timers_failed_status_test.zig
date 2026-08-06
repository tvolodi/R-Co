// tests/integration/iss101_timers_failed_status_test.zig
// Requirements: ISS-101
//
// Extend the timers.status CHECK constraint to include 'failed', enabling the scheduler
// (ISS-303) to move exhausted-retry timers to a terminal FAILED state. Migration 081
// replaces the existing CHECK constraint (pending, fired, cancelled) with one that
// includes 'failed'. The change is additive: existing rows are unaffected.
// The migration is idempotent.
//
// BPM_TEST_DB_URL must be set; the test connects to a real PostgreSQL.
// Each test provisions its own tenant schema via provisionTenantSchema, then opens
// a direct pg.Conn with search_path set to that schema for unqualified table access.
// Cleanup via defer — no shared state between tests.

const std = @import("std");
const portable_env = @import("env");
const pg = @import("pg");
const helpers = @import("helpers.zig");
const build_options = @import("build_options");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const provisionTenantSchema = bpm.provisioning.provisionTenantSchema;
const schemaNameForTenant = bpm.pool.schemaNameForTenant;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for ISS-101 integration tests\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn migrationsDir() []const u8 {
    return build_options.migrations_dir;
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 3,
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

/// Drop the provisioned tenant schema and remove tracking rows.
/// Best-effort — errors are printed but not propagated (used in defer).
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

/// Open a direct pg.Conn to the test database with search_path set to the given schema.
/// Caller is responsible for calling conn.close().
fn openTenantConn(
    allocator: std.mem.Allocator,
    url: []const u8,
    schema_name_str: []const u8,
) !pg.Conn {
    var conn = try pg.Conn.connectUrl(std.testing.io, allocator, url);
    errdefer conn.close();

    const sp_sql = try std.fmt.allocPrint(
        allocator,
        "SET search_path TO {s},public",
        .{schema_name_str},
    );
    defer allocator.free(sp_sql);
    try conn.exec(sp_sql, &.{});

    return conn;
}

/// Insert a minimal instance_projections row so the timers FK is satisfied.
/// ISS-0121 / GitHub #387: definition_id is generated per call rather than a
/// hardcoded literal so concurrent test binaries cannot collide on the FK.
fn insertInstanceProjection(
    allocator: std.mem.Allocator,
    conn: *pg.Conn,
    instance_id_hex: []const u8,
) !void {
    const definition_id_hex = try randomUuidStr(allocator);
    defer allocator.free(definition_id_hex);
    try conn.exec(
        \\INSERT INTO instance_projections
        \\    (instance_id, definition_id, status, last_event_seq)
        \\VALUES ($1::uuid, $2::uuid, 'ACTIVE', 0)
        \\ON CONFLICT (instance_id) DO NOTHING
    ,
        &.{ instance_id_hex, definition_id_hex },
    );
}

/// Insert a minimal timer row with status 'pending'.
fn insertPendingTimer(
    conn: *pg.Conn,
    timer_id_hex: []const u8,
    instance_id_hex: []const u8,
) !void {
    try conn.exec(
        \\INSERT INTO timers
        \\    (id, instance_id, timer_type, step_name, fires_at, action_type, action_config, status)
        \\VALUES
        \\    ($1::uuid, $2::uuid, 'scheduled_transition', 'WAIT_TIMER',
        \\     NOW() + INTERVAL '1 hour', 'auto_transition', '{}'::jsonb, 'pending')
    ,
        &.{ timer_id_hex, instance_id_hex },
    );
}

// ---------------------------------------------------------------------------
// TC-ISS-101-01: Update timer status to lowercase `failed` succeeds
// ---------------------------------------------------------------------------

test "iss101_timers_failed_status: update_timer_to_failed_succeeds" {
    // A timer row can be updated to status 'failed' after migration 081 extends the CHECK.
    // covers: ISS-101 AC-1, AC-3
    const allocator = std.testing.allocator;

    // TestHarness runs public-schema migrations so runMigrations has been called.
    var h = try helpers.TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(allocator);
    defer allocator.free(tenant_id);

    var schema_buf: [80]u8 = undefined;
    const schema_name_str = schemaNameForTenant(tenant_id, &schema_buf);

    defer cleanupTenant(allocator, &pool, tenant_id, schema_name_str);
    try provisionTenantSchema(allocator, &pool, tenant_id, migrationsDir());

    // Open a direct pg.Conn with search_path set to the freshly provisioned tenant schema.
    var conn = try openTenantConn(allocator, url, schema_name_str);
    defer conn.close();

    const instance_id = try randomUuidStr(allocator);
    defer allocator.free(instance_id);
    const timer_id = try randomUuidStr(allocator);
    defer allocator.free(timer_id);

    try insertInstanceProjection(allocator, &conn, instance_id);
    try insertPendingTimer(&conn, timer_id, instance_id);

    // Act: update status to lowercase 'failed'
    try conn.exec(
        "UPDATE timers SET status = 'failed' WHERE id = $1::uuid",
        &.{timer_id},
    );

    // Assert: the row now has status = 'failed'
    var rows = try conn.query(
        allocator,
        "SELECT status FROM timers WHERE id = $1::uuid",
        &.{timer_id},
    );
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    const status = rows.rows[0][0] orelse "";
    try std.testing.expectEqualStrings("failed", status);
}

// ---------------------------------------------------------------------------
// TC-ISS-101-02: Update timer status to uppercase `FAILED` succeeds (CHECK uses `lower()`)
// ---------------------------------------------------------------------------

test "iss101_timers_failed_status: update_timer_to_failed_uppercase_succeeds" {
    // The CHECK uses lower() so 'FAILED' (uppercase) is also accepted.
    // covers: ISS-101 AC-4
    const allocator = std.testing.allocator;

    var h = try helpers.TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(allocator);
    defer allocator.free(tenant_id);

    var schema_buf: [80]u8 = undefined;
    const schema_name_str = schemaNameForTenant(tenant_id, &schema_buf);

    defer cleanupTenant(allocator, &pool, tenant_id, schema_name_str);
    try provisionTenantSchema(allocator, &pool, tenant_id, migrationsDir());

    var conn = try openTenantConn(allocator, url, schema_name_str);
    defer conn.close();

    const instance_id = try randomUuidStr(allocator);
    defer allocator.free(instance_id);
    const timer_id = try randomUuidStr(allocator);
    defer allocator.free(timer_id);

    try insertInstanceProjection(allocator, &conn, instance_id);
    try insertPendingTimer(&conn, timer_id, instance_id);

    // Act: update status to uppercase 'FAILED' — CHECK uses lower() so it passes
    try conn.exec(
        "UPDATE timers SET status = 'FAILED' WHERE id = $1::uuid",
        &.{timer_id},
    );

    // Assert: the row now has status = 'FAILED' (stored as-is; CHECK normalises with lower())
    var rows = try conn.query(
        allocator,
        "SELECT status FROM timers WHERE id = $1::uuid",
        &.{timer_id},
    );
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    const status = rows.rows[0][0] orelse "";
    try std.testing.expectEqualStrings("FAILED", status);
}

// ---------------------------------------------------------------------------
// TC-ISS-101-03: Invalid status `BOGUS` is rejected by CHECK constraint
// ---------------------------------------------------------------------------

test "iss101_timers_failed_status: invalid_status_still_rejected" {
    // An arbitrary invalid status value is rejected by the CHECK constraint even after migration.
    // covers: ISS-101 AC-6
    //
    // A CHECK constraint violation (PG error 23514) aborts the current statement.
    // We use a SAVEPOINT so the connection survives the violation and we can
    // verify the timer row is still in its original 'pending' state.
    const allocator = std.testing.allocator;

    var h = try helpers.TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(allocator);
    defer allocator.free(tenant_id);

    var schema_buf: [80]u8 = undefined;
    const schema_name_str = schemaNameForTenant(tenant_id, &schema_buf);

    defer cleanupTenant(allocator, &pool, tenant_id, schema_name_str);
    try provisionTenantSchema(allocator, &pool, tenant_id, migrationsDir());

    var conn = try openTenantConn(allocator, url, schema_name_str);
    defer conn.close();

    const instance_id = try randomUuidStr(allocator);
    defer allocator.free(instance_id);
    const timer_id = try randomUuidStr(allocator);
    defer allocator.free(timer_id);

    try insertInstanceProjection(allocator, &conn, instance_id);
    try insertPendingTimer(&conn, timer_id, instance_id);

    // Begin a transaction to contain the SAVEPOINT.
    try conn.exec("BEGIN", &.{});

    // Establish a savepoint before the violating statement.
    try conn.exec("SAVEPOINT before_bogus", &.{});

    const update_result = conn.exec(
        "UPDATE timers SET status = 'BOGUS' WHERE id = $1::uuid",
        &.{timer_id},
    );

    // The UPDATE must fail with a server error (constraint violation 23514).
    try std.testing.expectError(error.ServerError, update_result);

    // Roll back to the savepoint to restore the connection to a usable state.
    try conn.exec("ROLLBACK TO SAVEPOINT before_bogus", &.{});

    // The timer status must still be 'pending' — the violating UPDATE was rejected.
    var rows = try conn.query(
        allocator,
        "SELECT status FROM timers WHERE id = $1::uuid",
        &.{timer_id},
    );
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    const status = rows.rows[0][0] orelse "";
    try std.testing.expectEqualStrings("pending", status);

    // Roll back the outer transaction (schema cleanup is via DROP SCHEMA in defer).
    conn.exec("ROLLBACK", &.{}) catch {};
}

// ---------------------------------------------------------------------------
// TC-ISS-101-04: Pre-existing status values (`pending`, `fired`, `cancelled`) remain valid
// ---------------------------------------------------------------------------

test "iss101_timers_failed_status: existing_statuses_remain_valid" {
    // Pre-existing status values (pending, fired, cancelled) still pass the constraint after migration.
    // covers: ISS-101 AC-5
    const allocator = std.testing.allocator;

    var h = try helpers.TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(allocator);
    defer allocator.free(tenant_id);

    var schema_buf: [80]u8 = undefined;
    const schema_name_str = schemaNameForTenant(tenant_id, &schema_buf);

    defer cleanupTenant(allocator, &pool, tenant_id, schema_name_str);
    try provisionTenantSchema(allocator, &pool, tenant_id, migrationsDir());

    var conn = try openTenantConn(allocator, url, schema_name_str);
    defer conn.close();

    const instance_id = try randomUuidStr(allocator);
    defer allocator.free(instance_id);
    const timer_pending = try randomUuidStr(allocator);
    defer allocator.free(timer_pending);
    const timer_fired = try randomUuidStr(allocator);
    defer allocator.free(timer_fired);
    const timer_cancelled = try randomUuidStr(allocator);
    defer allocator.free(timer_cancelled);

    try insertInstanceProjection(allocator, &conn, instance_id);

    // Insert timer with status 'pending'
    try conn.exec(
        \\INSERT INTO timers
        \\    (id, instance_id, timer_type, step_name, fires_at, action_type, action_config, status)
        \\VALUES
        \\    ($1::uuid, $2::uuid, 'scheduled_transition', 'STEP_PENDING',
        \\     NOW() + INTERVAL '1 hour', 'auto_transition', '{}'::jsonb, 'pending')
    ,
        &.{ timer_pending, instance_id },
    );

    // Insert timer with status 'fired'
    try conn.exec(
        \\INSERT INTO timers
        \\    (id, instance_id, timer_type, step_name, fires_at, action_type, action_config, status, fired_at)
        \\VALUES
        \\    ($1::uuid, $2::uuid, 'scheduled_transition', 'STEP_FIRED',
        \\     NOW() - INTERVAL '1 hour', 'auto_transition', '{}'::jsonb, 'fired', NOW())
    ,
        &.{ timer_fired, instance_id },
    );

    // Insert timer with status 'cancelled'
    try conn.exec(
        \\INSERT INTO timers
        \\    (id, instance_id, timer_type, step_name, fires_at, action_type, action_config, status, cancelled_at)
        \\VALUES
        \\    ($1::uuid, $2::uuid, 'scheduled_transition', 'STEP_CANCELLED',
        \\     NOW() - INTERVAL '2 hours', 'auto_transition', '{}'::jsonb, 'cancelled', NOW())
    ,
        &.{ timer_cancelled, instance_id },
    );

    // Assert: all three rows exist with their respective original status values.
    // ORDER BY status: cancelled, fired, pending
    var rows = try conn.query(
        allocator,
        \\SELECT id::text, status FROM timers
        \\WHERE id = ANY(ARRAY[$1::uuid, $2::uuid, $3::uuid])
        \\ORDER BY status
    ,
        &.{ timer_cancelled, timer_fired, timer_pending },
    );
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 3), rows.rows.len);
    const s0 = rows.rows[0][1] orelse "";
    const s1 = rows.rows[1][1] orelse "";
    const s2 = rows.rows[2][1] orelse "";
    try std.testing.expectEqualStrings("cancelled", s0);
    try std.testing.expectEqualStrings("fired", s1);
    try std.testing.expectEqualStrings("pending", s2);
}
