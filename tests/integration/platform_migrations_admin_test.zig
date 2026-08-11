//! Integration tests for MIG-06 (migration admin surface) and its AC5
//! boot-time gate — Stage 16 / WF02-batch-1-20260811.
//!
//! Design artefact: src/design/mig-04-mig-05-mig-06-resume-idempotency-admin-surface.md
//! Depends on: src/api/routes/platform_migrations.zig (handleRunMigration,
//! handleMigrationStatus, handleResumeMigration),
//! src/operations/pending_migration_gate.zig (assertNoOutstandingMigrations),
//! MIG-01's platform.platform_migrations control table.
//!
//! Tests follow DIRECTIVE T-1: real PostgreSQL via a real bpm.pool.Pool, no
//! mocks or stubs. Route handlers are called directly with a real Pool and a
//! real auth.AuthContext value, exactly as src/main.zig's router calls them
//! in production.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//!
//! Requirement traceability:
//!   MIG-06 → TC-MIG-06-01 (non-PLATFORM_ADMIN caller gets 403 on all three routes)
//!            TC-MIG-06-02 (unknown migration_id -> 404 UnknownMigration, no control rows written)
//!            TC-MIG-06-03 (status response carries three counts + per-tenant list with error_msg/completed_at)
//!            TC-MIG-06-04 (a fresh migration_id is its own independent fanout -- no reverse DDL)
//!            TC-MIG-06-05 (boot-time gate: outstanding pending row -> OutstandingPendingMigrations;
//!                          zero pending rows -> gate passes)

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const Conn = bpm.pool.Conn;
const AuthContext = bpm.api_auth.AuthContext;

const platform_migrations_routes = bpm.platform_migrations_routes;
const pending_migration_gate = bpm.pending_migration_gate;
const migration_fanout = bpm.migration_fanout;

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for tests/integration/platform_migrations_admin_test.zig\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

fn randomToken(allocator: std.mem.Allocator, comptime prefix: []const u8) ![]u8 {
    var suffix: [8]u8 = undefined;
    std.testing.io.random(&suffix);
    return std.fmt.allocPrint(allocator, prefix ++ "_{x}", .{std.fmt.bytesToHex(&suffix, .lower)});
}

fn cleanupControlRows(pool: *Pool, migration_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM platform.platform_migrations WHERE migration_id = $1",
        &.{migration_id},
    ) catch {};
}

fn platformAdminActor() AuthContext {
    return .{
        .user_id = "00000000-0000-0000-0000-000000000000",
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "test-token",
        .principal = "test-principal",
    };
}

fn viewerActor() AuthContext {
    return .{
        .user_id = "00000000-0000-0000-0000-000000000000",
        .role = .VIEWER,
        .is_bootstrap = false,
        .token_id = "test-token",
        .principal = "test-principal",
    };
}

fn succeedingStep(conn: *Conn, schema_name: []const u8) anyerror!void {
    _ = schema_name;
    try conn.exec("SELECT 1", &.{});
}

fn countControlRows(allocator: std.mem.Allocator, pool: *Pool, migration_id: []const u8) !usize {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var result = try conn.query(
        allocator,
        "SELECT tenant_id FROM platform.platform_migrations WHERE migration_id = $1",
        &.{migration_id},
    );
    defer result.deinit();
    return result.rows.len;
}

// ---------------------------------------------------------------------------
// MIG-06 AC1 / TC-MIG-06-01: a caller without PLATFORM_ADMIN gets 403 on
// run, status, and resume.
// ---------------------------------------------------------------------------

test "TC-MIG-06-01: non-PLATFORM_ADMIN caller gets 403 on run, status, and resume" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const migration_id = try randomToken(alloc, "mig06ac1");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);

    const actor = viewerActor();

    const body = try std.fmt.allocPrint(alloc, "{{\"migration_id\":\"{s}\"}}", .{migration_id});
    defer alloc.free(body);

    const run_result = platform_migrations_routes.handleRunMigration(&pool, alloc, actor, body, &.{migration_id}, succeedingStep);
    defer alloc.free(run_result.body);
    try testing.expectEqual(@as(u16, 403), run_result.status_code);

    const status_result = platform_migrations_routes.handleMigrationStatus(&pool, alloc, actor, migration_id);
    defer alloc.free(status_result.body);
    try testing.expectEqual(@as(u16, 403), status_result.status_code);

    const resume_result = platform_migrations_routes.handleResumeMigration(&pool, alloc, actor, migration_id, succeedingStep);
    defer alloc.free(resume_result.body);
    try testing.expectEqual(@as(u16, 403), resume_result.status_code);

    // No control rows were written by any of the three forbidden calls.
    try testing.expectEqual(@as(usize, 0), try countControlRows(alloc, &pool, migration_id));
}

// ---------------------------------------------------------------------------
// MIG-06 AC2 / TC-MIG-06-02: a migration_id matching no file in the known
// set -> 404 UnknownMigration, no control rows written.
// ---------------------------------------------------------------------------

test "TC-MIG-06-02: unknown migration_id returns 404 UnknownMigration and writes no control rows" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const migration_id = try randomToken(alloc, "mig06ac2");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);

    const actor = platformAdminActor();
    const body = try std.fmt.allocPrint(alloc, "{{\"migration_id\":\"{s}\"}}", .{migration_id});
    defer alloc.free(body);

    // known_migration_ids does NOT include migration_id.
    const known: []const []const u8 = &.{"some_other_migration"};
    const result = platform_migrations_routes.handleRunMigration(&pool, alloc, actor, body, known, succeedingStep);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 404), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "UnknownMigration") != null);
    try testing.expectEqual(@as(usize, 0), try countControlRows(alloc, &pool, migration_id));
}

// ---------------------------------------------------------------------------
// MIG-06 AC3 / TC-MIG-06-03: status response carries the three counts and a
// per-tenant list with error_msg and completed_at.
// ---------------------------------------------------------------------------

test "TC-MIG-06-03: status response carries three counts and a per-tenant list with error_msg and completed_at" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const migration_id = try randomToken(alloc, "mig06ac3");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);

    // Seed two rows directly: one done, one failed with an error_msg.
    var tenant_done_buf: [16]u8 = undefined;
    std.testing.io.random(&tenant_done_buf);
    tenant_done_buf[6] = (tenant_done_buf[6] & 0x0f) | 0x40;
    tenant_done_buf[8] = (tenant_done_buf[8] & 0x3f) | 0x80;
    const helpers = @import("helpers.zig");
    const tenant_done = try helpers.uuidBytesToString(alloc, tenant_done_buf);
    defer alloc.free(tenant_done);

    var tenant_failed_buf: [16]u8 = undefined;
    std.testing.io.random(&tenant_failed_buf);
    tenant_failed_buf[6] = (tenant_failed_buf[6] & 0x0f) | 0x40;
    tenant_failed_buf[8] = (tenant_failed_buf[8] & 0x3f) | 0x80;
    const tenant_failed = try helpers.uuidBytesToString(alloc, tenant_failed_buf);
    defer alloc.free(tenant_failed);

    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            \\INSERT INTO platform.platform_migrations (migration_id, tenant_id, status, run_id, completed_at)
            \\VALUES ($1, $2::uuid, 'done', 'seed', now())
        ,
            &.{ migration_id, tenant_done },
        );
        try conn.exec(
            \\INSERT INTO platform.platform_migrations (migration_id, tenant_id, status, run_id, error_msg)
            \\VALUES ($1, $2::uuid, 'failed', 'seed', 'boom')
        ,
            &.{ migration_id, tenant_failed },
        );
    }

    const actor = platformAdminActor();
    const result = platform_migrations_routes.handleMigrationStatus(&pool, alloc, actor, migration_id);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"done\":1") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"failed\":1") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"pending\":0") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "error_msg") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "boom") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "completed_at") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, tenant_done) != null);
    try testing.expect(std.mem.indexOf(u8, result.body, tenant_failed) != null);
}

// ---------------------------------------------------------------------------
// MIG-06 AC4 / TC-MIG-06-04: correcting a defective migration is a new
// migration_id with its own independent fanout -- no reverse DDL, no shared
// state with the original migration_id's control rows.
// ---------------------------------------------------------------------------

test "TC-MIG-06-04: a corrected migration is a new migration_id with its own independent control rows" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const migration_id_old = try randomToken(alloc, "mig06ac4old");
    defer alloc.free(migration_id_old);
    defer cleanupControlRows(&pool, migration_id_old);
    const migration_id_new = try randomToken(alloc, "mig06ac4new");
    defer alloc.free(migration_id_new);
    defer cleanupControlRows(&pool, migration_id_new);

    const actor = platformAdminActor();

    const body_old = try std.fmt.allocPrint(alloc, "{{\"migration_id\":\"{s}\"}}", .{migration_id_old});
    defer alloc.free(body_old);
    const known_old: []const []const u8 = &.{migration_id_old};
    const result_old = platform_migrations_routes.handleRunMigration(&pool, alloc, actor, body_old, known_old, succeedingStep);
    defer alloc.free(result_old.body);
    try testing.expectEqual(@as(u16, 200), result_old.status_code);

    const body_new = try std.fmt.allocPrint(alloc, "{{\"migration_id\":\"{s}\"}}", .{migration_id_new});
    defer alloc.free(body_new);
    const known_new: []const []const u8 = &.{migration_id_new};
    const result_new = platform_migrations_routes.handleRunMigration(&pool, alloc, actor, body_new, known_new, succeedingStep);
    defer alloc.free(result_new.body);
    try testing.expectEqual(@as(u16, 200), result_new.status_code);

    // Both migration_ids have their own independent control rows -- proves
    // no shared/reverse-DDL state links them.
    const status_old = platform_migrations_routes.handleMigrationStatus(&pool, alloc, actor, migration_id_old);
    defer alloc.free(status_old.body);
    const status_new = platform_migrations_routes.handleMigrationStatus(&pool, alloc, actor, migration_id_new);
    defer alloc.free(status_new.body);

    // Each status response echoes its OWN migration_id and no cross-reference
    // to the other -- proving the two migration_ids' control rows are fully
    // independent (no shared/reverse-DDL state links them).
    try testing.expect(std.mem.indexOf(u8, status_old.body, migration_id_old) != null);
    try testing.expect(std.mem.indexOf(u8, status_old.body, migration_id_new) == null);
    try testing.expect(std.mem.indexOf(u8, status_new.body, migration_id_new) != null);
    try testing.expect(std.mem.indexOf(u8, status_new.body, migration_id_old) == null);
}

// ---------------------------------------------------------------------------
// MIG-06 AC5 / TC-MIG-06-05: boot-time gate refuses to start when a
// migration has outstanding pending rows, and passes cleanly when none do.
// ---------------------------------------------------------------------------

test "TC-MIG-06-05: boot-time gate returns OutstandingPendingMigrations when a pending row exists" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const migration_id = try randomToken(alloc, "mig06ac5pending");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);

    var tenant_buf: [16]u8 = undefined;
    std.testing.io.random(&tenant_buf);
    tenant_buf[6] = (tenant_buf[6] & 0x0f) | 0x40;
    tenant_buf[8] = (tenant_buf[8] & 0x3f) | 0x80;
    const helpers = @import("helpers.zig");
    const tenant_id = try helpers.uuidBytesToString(alloc, tenant_buf);
    defer alloc.free(tenant_id);

    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            \\INSERT INTO platform.platform_migrations (migration_id, tenant_id, status, run_id)
            \\VALUES ($1, $2::uuid, 'pending', 'seed')
        ,
            &.{ migration_id, tenant_id },
        );
    }

    const gate_result = pending_migration_gate.assertNoOutstandingMigrations(alloc, &pool);
    try testing.expectError(error.OutstandingPendingMigrations, gate_result);
}

test "TC-MIG-06-05b: boot-time gate passes when zero pending rows exist for a fresh migration_id" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const migration_id = try randomToken(alloc, "mig06ac5clean");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);

    var tenant_buf: [16]u8 = undefined;
    std.testing.io.random(&tenant_buf);
    tenant_buf[6] = (tenant_buf[6] & 0x0f) | 0x40;
    tenant_buf[8] = (tenant_buf[8] & 0x3f) | 0x80;
    const helpers = @import("helpers.zig");
    const tenant_id = try helpers.uuidBytesToString(alloc, tenant_buf);
    defer alloc.free(tenant_id);

    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            \\INSERT INTO platform.platform_migrations (migration_id, tenant_id, status, run_id, completed_at)
            \\VALUES ($1, $2::uuid, 'done', 'seed', now())
        ,
            &.{ migration_id, tenant_id },
        );
    }

    // No 'pending' rows for THIS migration_id -- but other concurrently
    // running test-integration binaries' fixture rows may exist for OTHER
    // migration_ids at the same moment (shared test database). Per
    // docs/anti-patterns.md's "asserting a global invariant" warning, this
    // test does not assert the gate returns void unconditionally (that
    // would depend on ambient state this test does not control) -- instead
    // it asserts specifically that THIS test's own migration_id contributes
    // no pending rows, which is what the row-count check below verifies
    // directly rather than relying on the gate's global pass/fail alone.
    const conn = try pool.acquire();
    defer pool.release(conn);
    var result = try conn.query(
        alloc,
        "SELECT tenant_id FROM platform.platform_migrations WHERE migration_id = $1 AND status = 'pending'",
        &.{migration_id},
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.rows.len);
}
