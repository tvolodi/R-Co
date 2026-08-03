// tests/integration/iss106_webhook_outbox_test.zig
// Requirements: ISS-106
//
// ISS-106 formalizes the existing webhook_deliveries table into the transactional-outbox
// contract. Migration 085 (085_iss106_webhook_deliveries_outbox.sql):
//   - adds `attempt INTEGER NOT NULL DEFAULT 0`,
//   - remaps legacy lowercase status values and installs the uppercase status-domain CHECK
//     `webhook_deliveries_status_check` over (PENDING, DELIVERED, FAILED, RETRYING),
//   - re-asserts the worker-claim index `idx_wd_status_next_attempt` on (status, next_attempt_at).
//
// This suite verifies the TABLE SHAPE / CONSTRAINTS produced by the migration against a real
// PostgreSQL instance. It does NOT exercise the transactional-outbox INSERT path or the
// FOR UPDATE SKIP LOCKED worker-claim query — those are ISS-205 and are explicitly deferred.
//
// BPM_TEST_DB_URL must be set; the test connects to a real PostgreSQL.
// Each test provisions its own tenant schema via provisionTenantSchema, then opens a direct
// pg.Conn with search_path set to that schema for unqualified table access. webhook_deliveries
// requires a subscription_id FK to webhook_subscriptions, whose owner_id FKs to users, so each
// test creates a throwaway user + subscription (per-test UUIDs) inside the provisioned schema.
// Cleanup via defer (DROP SCHEMA) — no shared state between tests.

const std = @import("std");
const pg = @import("pg");
const helpers = @import("helpers.zig");
const build_options = @import("build_options");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const provisionTenantSchema = bpm.provisioning.provisionTenantSchema;
const schemaNameForTenant = bpm.pool.schemaNameForTenant;

// ---------------------------------------------------------------------------
// Shared helpers (mirror iss101_timers_failed_status_test.zig idioms)
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for ISS-106 integration tests\n", .{});
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

/// Seed a throwaway user (FK target for webhook_subscriptions.owner_id) in the current schema.
fn insertOwnerUser(
    conn: *pg.Conn,
    user_id: []const u8,
    email: []const u8,
    username: []const u8,
) !void {
    try conn.exec(
        \\INSERT INTO users (id, email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1::uuid, $2, 'ISS-106 Owner', 'hash', true, $3, 'ACTIVE')
    ,
        &.{ user_id, email, username },
    );
}

/// Seed a throwaway webhook subscription (FK target for webhook_deliveries.subscription_id).
fn insertSubscription(
    conn: *pg.Conn,
    subscription_id: []const u8,
    owner_id: []const u8,
) !void {
    try conn.exec(
        \\INSERT INTO webhook_subscriptions (
        \\  id, owner_id, url, secret, event_types, is_active, created_at, updated_at
        \\)
        \\VALUES (
        \\  $1::uuid, $2::uuid, 'http://127.0.0.1:1/hook', '', ARRAY['task.completed']::text[],
        \\  true, NOW(), NOW()
        \\)
    ,
        &.{ subscription_id, owner_id },
    );
}

// ---------------------------------------------------------------------------
// TC-ISS-106-01: `attempt` column is INTEGER NOT NULL DEFAULT 0
// ---------------------------------------------------------------------------

test "iss106_webhook_outbox: attempt_column_is_integer_not_null_default_zero" {
    // covers: ISS-106 — attempt column shape (design Step 1)
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

    // Inspect the column metadata, scoped to the freshly provisioned schema.
    var rows = try conn.query(
        allocator,
        \\SELECT data_type, is_nullable, column_default
        \\FROM information_schema.columns
        \\WHERE table_schema = current_schema()
        \\  AND table_name = 'webhook_deliveries'
        \\  AND column_name = 'attempt'
    ,
        &.{},
    );
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    const data_type = rows.rows[0][0] orelse "";
    const is_nullable = rows.rows[0][1] orelse "";
    const column_default = rows.rows[0][2] orelse "";

    try std.testing.expectEqualStrings("integer", data_type);
    try std.testing.expectEqualStrings("NO", is_nullable);
    // Default is rendered as the literal `0` by PostgreSQL.
    try std.testing.expectEqualStrings("0", column_default);
}

// ---------------------------------------------------------------------------
// TC-ISS-106-02: each valid status value is accepted by the CHECK
// ---------------------------------------------------------------------------

test "iss106_webhook_outbox: valid_status_domain_accepted" {
    // covers: ISS-106 — status domain (PENDING, DELIVERED, FAILED, RETRYING) (design Step 4)
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

    const owner_id = try randomUuidStr(allocator);
    defer allocator.free(owner_id);
    const subscription_id = try randomUuidStr(allocator);
    defer allocator.free(subscription_id);

    try insertOwnerUser(&conn, owner_id, "iss106-int02@example.test", "iss106_int02");
    try insertSubscription(&conn, subscription_id, owner_id);

    const valid_statuses = [_][]const u8{ "PENDING", "DELIVERED", "FAILED", "RETRYING" };
    for (valid_statuses) |status| {
        const delivery_id = try randomUuidStr(allocator);
        defer allocator.free(delivery_id);

        try conn.exec(
            \\INSERT INTO webhook_deliveries
            \\    (id, subscription_id, event_id, status, attempt, next_attempt_at, created_at)
            \\VALUES
            \\    ($1::uuid, $2::uuid, NULL, $3, 0, NOW(), NOW())
        ,
            &.{ delivery_id, subscription_id, status },
        );

        // Round-trip: the row persisted with the requested status.
        var rows = try conn.query(
            allocator,
            "SELECT status FROM webhook_deliveries WHERE id = $1::uuid",
            &.{delivery_id},
        );
        defer rows.deinit();

        try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
        const persisted = rows.rows[0][0] orelse "";
        try std.testing.expectEqualStrings(status, persisted);
    }
}

// ---------------------------------------------------------------------------
// TC-ISS-106-03: out-of-domain status values are rejected by the CHECK
// ---------------------------------------------------------------------------

test "iss106_webhook_outbox: out_of_domain_status_rejected" {
    // covers: ISS-106 — webhook_deliveries_status_check rejects values outside the uppercase
    // domain, including the legacy lowercase 'pending' (design Step 4)
    //
    // A CHECK violation (PG error 23514) aborts the current statement. We use a SAVEPOINT so
    // the connection survives each rejection and we can verify no row was persisted.
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

    const owner_id = try randomUuidStr(allocator);
    defer allocator.free(owner_id);
    const subscription_id = try randomUuidStr(allocator);
    defer allocator.free(subscription_id);

    try insertOwnerUser(&conn, owner_id, "iss106-int03@example.test", "iss106_int03");
    try insertSubscription(&conn, subscription_id, owner_id);

    try conn.exec("BEGIN", &.{});

    // Rejected value #1: an arbitrary out-of-domain status.
    {
        const delivery_id = try randomUuidStr(allocator);
        defer allocator.free(delivery_id);

        try conn.exec("SAVEPOINT before_bogus", &.{});
        const insert_result = conn.exec(
            \\INSERT INTO webhook_deliveries
            \\    (id, subscription_id, event_id, status, attempt, next_attempt_at, created_at)
            \\VALUES
            \\    ($1::uuid, $2::uuid, NULL, 'BOGUS', 0, NOW(), NOW())
        ,
            &.{ delivery_id, subscription_id },
        );
        try std.testing.expectError(error.ServerError, insert_result);
        try conn.exec("ROLLBACK TO SAVEPOINT before_bogus", &.{});
    }

    // Rejected value #2: the legacy lowercase 'pending' — no longer in the uppercase domain.
    {
        const delivery_id = try randomUuidStr(allocator);
        defer allocator.free(delivery_id);

        try conn.exec("SAVEPOINT before_legacy", &.{});
        const insert_result = conn.exec(
            \\INSERT INTO webhook_deliveries
            \\    (id, subscription_id, event_id, status, attempt, next_attempt_at, created_at)
            \\VALUES
            \\    ($1::uuid, $2::uuid, NULL, 'PENDING', 0, NOW(), NOW())
        ,
            &.{ delivery_id, subscription_id },
        );
        try std.testing.expectError(error.ServerError, insert_result);
        try conn.exec("ROLLBACK TO SAVEPOINT before_legacy", &.{});
    }

    // No webhook_deliveries row was persisted for this subscription.
    var rows = try conn.query(
        allocator,
        "SELECT COUNT(*)::text FROM webhook_deliveries WHERE subscription_id = $1::uuid",
        &.{subscription_id},
    );
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    const count = rows.rows[0][0] orelse "";
    try std.testing.expectEqualStrings("0", count);

    conn.exec("ROLLBACK", &.{}) catch {};
}

// ---------------------------------------------------------------------------
// TC-ISS-106-04: worker-claim index idx_wd_status_next_attempt exists on (status, next_attempt_at)
// ---------------------------------------------------------------------------

test "iss106_webhook_outbox: worker_claim_index_present" {
    // covers: ISS-106 — index (status, next_attempt_at) for worker claim (design Step 5)
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

    // The index must exist in this schema, on the webhook_deliveries table.
    var rows = try conn.query(
        allocator,
        \\SELECT indexdef
        \\FROM pg_indexes
        \\WHERE schemaname = current_schema()
        \\  AND tablename = 'webhook_deliveries'
        \\  AND indexname = 'idx_wd_status_next_attempt'
    ,
        &.{},
    );
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    const indexdef = rows.rows[0][0] orelse "";

    // The index definition must cover both claim columns.
    try std.testing.expect(std.mem.indexOf(u8, indexdef, "status") != null);
    try std.testing.expect(std.mem.indexOf(u8, indexdef, "next_attempt_at") != null);
}

// ---------------------------------------------------------------------------
// TC-ISS-106-05: full-contract row round-trips with correct values
// ---------------------------------------------------------------------------

test "iss106_webhook_outbox: full_contract_row_round_trips" {
    // covers: ISS-106 — full outbox contract column set
    // (id as delivery_id, subscription_id, event_id, status, attempt, next_attempt_at,
    //  last_error, created_at) persists and reads back intact.
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

    const owner_id = try randomUuidStr(allocator);
    defer allocator.free(owner_id);
    const subscription_id = try randomUuidStr(allocator);
    defer allocator.free(subscription_id);
    const delivery_id = try randomUuidStr(allocator);
    defer allocator.free(delivery_id);

    try insertOwnerUser(&conn, owner_id, "iss106-int05@example.test", "iss106_int05");
    try insertSubscription(&conn, subscription_id, owner_id);

    // Write the full contract column set. event_id is nullable (migration 025) and the events
    // table is empty in a freshly provisioned schema, so it is set to NULL to satisfy the FK
    // (the round-trip asserts event_id IS NULL). The remaining contract columns carry concrete
    // values to verify they persist exactly.
    try conn.exec(
        \\INSERT INTO webhook_deliveries
        \\    (id, subscription_id, event_id, status, attempt, next_attempt_at, last_error, created_at)
        \\VALUES
        \\    ($1::uuid, $2::uuid, NULL, 'RETRYING', 3,
        \\     TIMESTAMPTZ '2026-06-11 12:00:00+00', 'connection refused',
        \\     TIMESTAMPTZ '2026-06-11 11:00:00+00')
    ,
        &.{ delivery_id, subscription_id },
    );

    var rows = try conn.query(
        allocator,
        \\SELECT id::text, subscription_id::text, status, attempt::text,
        \\       to_char(next_attempt_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'),
        \\       last_error,
        \\       to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'),
        \\       (event_id IS NULL)::text
        \\FROM webhook_deliveries
        \\WHERE id = $1::uuid
    ,
        &.{delivery_id},
    );
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    const r = rows.rows[0];
    try std.testing.expectEqualStrings(delivery_id, r[0] orelse "");
    try std.testing.expectEqualStrings(subscription_id, r[1] orelse "");
    try std.testing.expectEqualStrings("RETRYING", r[2] orelse "");
    try std.testing.expectEqualStrings("3", r[3] orelse "");
    try std.testing.expectEqualStrings("2026-06-11 12:00:00", r[4] orelse "");
    try std.testing.expectEqualStrings("connection refused", r[5] orelse "");
    try std.testing.expectEqualStrings("2026-06-11 11:00:00", r[6] orelse "");
    try std.testing.expectEqualStrings("true", r[7] orelse "");
}
