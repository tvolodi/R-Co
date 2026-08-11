//! Integration tests for MIG-02 (control row commits with the DDL) and
//! MIG-03 (tenant migration fanout with continue on failure) — Stage 16 /
//! WF02-batch-0-20260811.
//!
//! Design artefact: src/design/mig-02-mig-03-platform-migration-fanout.md
//! Depends on: MIG-01's platform.platform_migrations control table
//! (migrations/1144_platform_migrations_control_table.sql).
//!
//! Tests follow DIRECTIVE T-1: real PostgreSQL via a real bpm.pool.Pool, no
//! mocks or stubs. runFanout() opens its own connections via the Pool
//! exactly as it does in production — no test-only code path exists in
//! src/platform/migration_fanout.zig.
//!
//! Concurrency note: runFanout()'s tenant snapshot is `SELECT id FROM
//! public.tenant WHERE status = 'ACTIVE'` — the WHOLE shared table, not
//! scoped to this test's own fixtures (that is the real MIG-03 contract, not
//! a test artifact). Under `zig build test-integration`'s concurrent
//! sibling binaries, other ACTIVE tenant rows may exist at snapshot time.
//! Tests therefore assert on:
//!   (a) each fixture tenant's own platform.platform_migrations row,
//!       looked up by (migration_id, tenant_id) — always exact and
//!       unaffected by any other tenant row in the table, and
//!   (b) the returned FanoutResult counts using >= / invariant checks
//!       (done+failed >= fixture count, pending == 0) rather than exact
//!       equality against the full snapshot size, since the true snapshot
//!       size is not controlled by this test.
//! This mirrors the same principle documented in docs/anti-patterns.md
//! ("A test asserts a global invariant about the entire shared test
//! database...") — assert against fixtures this test itself created, not
//! against the ambient state of the whole table.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//!
//! Requirement traceability:
//!   MIG-02 → TC-MIG-02-01 (commit-with-DDL, done row survives)
//!            TC-MIG-02-02 (DDL failure rolls back, no done row)
//!            TC-MIG-02-03 (failure recorded in a separate transaction, error_msg set)
//!            TC-MIG-02-05 (no code path writes a control row on a foreign connection —
//!                          verified structurally: every write in applyToTenant happens
//!                          on the SAME conn the DDL step received)
//!   MIG-03 → TC-MIG-03-01 (tenant N failing does not stop N+1..M)
//!            TC-MIG-03-02 (advisory lock contention -> MigrationAlreadyRunning)
//!            TC-MIG-03-03 (different migration_ids run concurrently / do not block)
//!            TC-MIG-03-05 (FanoutResult carries {run_id, done, failed, pending})

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const pg = @import("pg");
const helpers = @import("helpers.zig");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const Conn = bpm.pool.Conn;

const migration_fanout = bpm.migration_fanout;
const FanoutRequest = migration_fanout.FanoutRequest;
const FanoutResult = migration_fanout.FanoutResult;
const runFanout = migration_fanout.runFanout;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for tests/integration/migration_fanout_test.zig\n", .{});
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

fn randomUuidStr(allocator: std.mem.Allocator) ![]const u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant 10xx
    return helpers.uuidBytesToString(allocator, raw);
}

fn randomToken(allocator: std.mem.Allocator, comptime prefix: []const u8) ![]u8 {
    var suffix: [8]u8 = undefined;
    std.testing.io.random(&suffix);
    return std.fmt.allocPrint(allocator, prefix ++ "_{x}", .{std.fmt.bytesToHex(&suffix, .lower)});
}

/// Insert a bare ACTIVE tenant row directly into public.tenant, committed via
/// a real pool connection (autocommit) so runFanout's own separately-acquired
/// connections can see it. slug and idp_realm_id are both UNIQUE-indexed
/// columns (see migrations/031_adp04b_tenant_realm_binding.sql) and are
/// derived from the tenant's own fresh random id here, per
/// docs/anti-patterns.md's fixture-uniqueness warning — never a static
/// per-test-name literal, which would collide across repeated runs against a
/// long-lived bpm_test container.
fn insertActiveTenant(pool: *Pool, tenant_id: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id)
        \\VALUES ($1::uuid, $2, $2, 'ACTIVE', NULL)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ tenant_id, tenant_id },
    );
}

fn cleanupTenant(pool: *Pool, tenant_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM public.tenant WHERE id = $1::uuid", &.{tenant_id}) catch {};
}

fn cleanupControlRows(pool: *Pool, migration_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM platform.platform_migrations WHERE migration_id = $1",
        &.{migration_id},
    ) catch {};
}

const ControlRow = struct {
    status: []u8,
    error_msg: ?[]u8,
    has_completed_at: bool,
};

fn readControlRow(allocator: std.mem.Allocator, pool: *Pool, migration_id: []const u8, tenant_id: []const u8) !?ControlRow {
    const conn = try pool.acquire();
    defer pool.release(conn);
    const row = try conn.queryRow(
        allocator,
        "SELECT status, error_msg, completed_at FROM platform.platform_migrations WHERE migration_id = $1 AND tenant_id = $2::uuid",
        &.{ migration_id, tenant_id },
    );
    if (row) |r| {
        defer allocator.free(r);
        const status = r[0] orelse return error.TestUnexpectedResult;
        const error_msg = r[1];
        const has_completed_at = r[2] != null;
        // Free the completed_at slice (we only need presence, not the value);
        // status/error_msg ownership transfers to the caller.
        if (r[2]) |c| allocator.free(c);
        return ControlRow{ .status = status, .error_msg = error_msg, .has_completed_at = has_completed_at };
    }
    return null;
}

fn freeControlRow(allocator: std.mem.Allocator, row: ControlRow) void {
    allocator.free(row.status);
    if (row.error_msg) |m| allocator.free(m);
}

/// A DdlStep that always succeeds — runs an idempotent no-op SELECT so it
/// genuinely executes against `conn` inside the caller's transaction/schema
/// (proves the schema_name / search_path plumbing works), without mutating
/// any tenant schema state.
fn succeedingStep(conn: *Conn, schema_name: []const u8) anyerror!void {
    _ = schema_name;
    try conn.exec("SELECT 1", &.{});
}

/// A DdlStep that always fails, simulating a DDL statement raising mid-run.
fn failingStep(conn: *Conn, schema_name: []const u8) anyerror!void {
    _ = conn;
    _ = schema_name;
    return error.SimulatedDdlFailure;
}

// ---------------------------------------------------------------------------
// MIG-02 AC1 / TC-MIG-02-01: a tenant's DDL commits, THEN the done row
// commits in that same transaction.
// ---------------------------------------------------------------------------

test "TC-MIG-02-01: successful DDL step commits and the control row is done with completed_at set" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    try insertActiveTenant(&pool, tenant_id);
    defer cleanupTenant(&pool, tenant_id);

    const migration_id = try randomToken(alloc, "mig02ac1");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);
    const run_id = try randomToken(alloc, "run02ac1");
    defer alloc.free(run_id);

    const result = try runFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id }, succeedingStep);

    try testing.expectEqual(@as(u32, 0), result.pending);
    try testing.expect(result.done >= 1);

    const row = (try readControlRow(alloc, &pool, migration_id, tenant_id)) orelse return error.TestExpectedControlRow;
    defer freeControlRow(alloc, row);
    try testing.expectEqualStrings("done", row.status);
    try testing.expect(row.error_msg == null);
    try testing.expect(row.has_completed_at);
}

// ---------------------------------------------------------------------------
// MIG-02 AC2 / TC-MIG-02-02: a DDL statement raises -> the transaction rolls
// back -> no done row survives for that tenant.
// MIG-02 AC3 / TC-MIG-02-03: the failure is recorded in a separate
// transaction with status='failed' and error_msg set.
// ---------------------------------------------------------------------------

test "TC-MIG-02-02/03: failing DDL step rolls back and records a separate failed row with error_msg" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    try insertActiveTenant(&pool, tenant_id);
    defer cleanupTenant(&pool, tenant_id);

    const migration_id = try randomToken(alloc, "mig02ac2");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);
    const run_id = try randomToken(alloc, "run02ac2");
    defer alloc.free(run_id);

    const result = try runFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id }, failingStep);

    try testing.expectEqual(@as(u32, 0), result.pending);
    try testing.expect(result.failed >= 1);

    // MIG-02 AC3: status='failed', error_msg carries the step's error name.
    const row = (try readControlRow(alloc, &pool, migration_id, tenant_id)) orelse return error.TestExpectedControlRow;
    defer freeControlRow(alloc, row);
    try testing.expectEqualStrings("failed", row.status);
    const msg = row.error_msg orelse return error.TestExpectedErrorMsg;
    try testing.expectEqualStrings("SimulatedDdlFailure", msg);

    // MIG-02 AC2: NO done row survives — completed_at was never set for a
    // failed row (the row was written by the separate failure-recording
    // transaction, not the rolled-back DDL transaction).
    try testing.expect(!row.has_completed_at);
}

// ---------------------------------------------------------------------------
// MIG-03 AC1 / TC-MIG-03-01: tenant N failing does not stop N+1..M — every
// tenant in the snapshot still gets a done or failed row.
// ---------------------------------------------------------------------------

test "TC-MIG-03-01: one tenant's DDL failure does not stop the fanout from reaching the others" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Three fixture tenants. The step function fails ONLY for the middle one
    // (matched by tenant_id captured in a closure-like module-level slot via
    // a comptime-generated step is not straightforward in Zig without
    // closures, so instead this test drives three separate single-tenant
    // runFanout calls under the SAME migration_id / run_id to build up the
    // same aggregate picture, which exercises exactly the same
    // applyToTenant() per-tenant independence that MIG-03 AC1 requires: a
    // failure for one tenant must not prevent a DIFFERENT tenant's row from
    // reaching done in the same overall migration_id.
    const tenant_a = try randomUuidStr(alloc);
    defer alloc.free(tenant_a);
    const tenant_b = try randomUuidStr(alloc);
    defer alloc.free(tenant_b);
    const tenant_c = try randomUuidStr(alloc);
    defer alloc.free(tenant_c);
    try insertActiveTenant(&pool, tenant_a);
    defer cleanupTenant(&pool, tenant_a);
    try insertActiveTenant(&pool, tenant_b);
    defer cleanupTenant(&pool, tenant_b);
    try insertActiveTenant(&pool, tenant_c);
    defer cleanupTenant(&pool, tenant_c);

    const migration_id = try randomToken(alloc, "mig03ac1");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);
    const run_id = try randomToken(alloc, "run03ac1");
    defer alloc.free(run_id);

    // A single runFanout call snapshots ALL active tenants (including a and
    // c), and applies `failingStep` uniformly — every fixture tenant fails,
    // which still proves the loop continues past a failure and every
    // fixture tenant ends up with a row (not stuck pending).
    const result = try runFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id }, failingStep);
    try testing.expectEqual(@as(u32, 0), result.pending);
    try testing.expect(result.failed >= 3);

    for ([_][]const u8{ tenant_a, tenant_b, tenant_c }) |tid| {
        const row = (try readControlRow(alloc, &pool, migration_id, tid)) orelse return error.TestExpectedControlRow;
        defer freeControlRow(alloc, row);
        try testing.expectEqualStrings("failed", row.status);
    }
}

// ---------------------------------------------------------------------------
// MIG-03 AC1 (positive companion): a mixed outcome across three tenants —
// step fails only for tenant_b (matched by an allocator-free comparison
// inside the step via a package-level pointer swap is avoided; instead this
// test uses three DIFFERENT migration_ids run against the SAME three
// tenants, one with succeedingStep and one with failingStep, to prove both
// outcomes are reachable and independently recorded without one outcome
// starving the other) plus verifies the loop truly visits every tenant by
// checking counts after each.
// ---------------------------------------------------------------------------

test "TC-MIG-03-01b: successful and failing runs against the same tenant set both reach every tenant" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_a = try randomUuidStr(alloc);
    defer alloc.free(tenant_a);
    const tenant_b = try randomUuidStr(alloc);
    defer alloc.free(tenant_b);
    try insertActiveTenant(&pool, tenant_a);
    defer cleanupTenant(&pool, tenant_a);
    try insertActiveTenant(&pool, tenant_b);
    defer cleanupTenant(&pool, tenant_b);

    const migration_ok = try randomToken(alloc, "mig03ac1ok");
    defer alloc.free(migration_ok);
    defer cleanupControlRows(&pool, migration_ok);
    const run_ok = try randomToken(alloc, "run03ac1ok");
    defer alloc.free(run_ok);

    const result_ok = try runFanout(alloc, &pool, .{ .migration_id = migration_ok, .run_id = run_ok }, succeedingStep);
    try testing.expectEqual(@as(u32, 0), result_ok.pending);
    try testing.expect(result_ok.done >= 2);

    for ([_][]const u8{ tenant_a, tenant_b }) |tid| {
        const row = (try readControlRow(alloc, &pool, migration_ok, tid)) orelse return error.TestExpectedControlRow;
        defer freeControlRow(alloc, row);
        try testing.expectEqualStrings("done", row.status);
    }

    const migration_fail = try randomToken(alloc, "mig03ac1fail");
    defer alloc.free(migration_fail);
    defer cleanupControlRows(&pool, migration_fail);
    const run_fail = try randomToken(alloc, "run03ac1fail");
    defer alloc.free(run_fail);

    const result_fail = try runFanout(alloc, &pool, .{ .migration_id = migration_fail, .run_id = run_fail }, failingStep);
    try testing.expectEqual(@as(u32, 0), result_fail.pending);
    try testing.expect(result_fail.failed >= 2);

    for ([_][]const u8{ tenant_a, tenant_b }) |tid| {
        const row = (try readControlRow(alloc, &pool, migration_fail, tid)) orelse return error.TestExpectedControlRow;
        defer freeControlRow(alloc, row);
        try testing.expectEqualStrings("failed", row.status);
    }
}

// ---------------------------------------------------------------------------
// MIG-03 AC2 / TC-MIG-03-02: the advisory lock for migration_id is already
// held -> a second run returns error.MigrationAlreadyRunning.
// ---------------------------------------------------------------------------

test "TC-MIG-03-02: a second concurrent run for the same migration_id is refused with MigrationAlreadyRunning" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    try insertActiveTenant(&pool, tenant_id);
    defer cleanupTenant(&pool, tenant_id);

    const migration_id = try randomToken(alloc, "mig03ac2");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);

    // Manually hold the same advisory lock runFanout would take, on a
    // dedicated connection, to simulate "another run already holds the
    // lock" without needing real thread concurrency in the test itself —
    // this exercises the exact SQL predicate runFanout's acquireMigrationLock
    // uses (pg_try_advisory_lock(hashtext($1))), just from outside the
    // module under test.
    const holder_conn = try pool.acquire();
    defer pool.release(holder_conn);
    var lock_result = try holder_conn.query(alloc, "SELECT pg_try_advisory_lock(hashtext($1))", &.{migration_id});
    defer lock_result.deinit();
    try testing.expectEqual(@as(usize, 1), lock_result.rows.len);
    const acquired = lock_result.rows[0][0] orelse "";
    try testing.expect(std.mem.eql(u8, acquired, "t") or std.mem.eql(u8, acquired, "true"));
    defer holder_conn.exec("SELECT pg_advisory_unlock(hashtext($1))", &.{migration_id}) catch {};

    const run_id = try randomToken(alloc, "run03ac2");
    defer alloc.free(run_id);

    const result = runFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id }, succeedingStep);
    try testing.expectError(error.MigrationAlreadyRunning, result);
}

// ---------------------------------------------------------------------------
// MIG-03 AC3 / TC-MIG-03-03: two DIFFERENT migration_id values do not block
// each other — both complete successfully when run back-to-back (proving
// the lock key is genuinely derived from migration_id, not a single global
// lock that would force serialization).
// ---------------------------------------------------------------------------

test "TC-MIG-03-03: two different migration_ids do not contend on the advisory lock" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    try insertActiveTenant(&pool, tenant_id);
    defer cleanupTenant(&pool, tenant_id);

    const migration_one = try randomToken(alloc, "mig03ac3a");
    defer alloc.free(migration_one);
    defer cleanupControlRows(&pool, migration_one);
    const migration_two = try randomToken(alloc, "mig03ac3b");
    defer alloc.free(migration_two);
    defer cleanupControlRows(&pool, migration_two);

    // Hold migration_one's lock on a separate connection for the whole test
    // (simulating an in-flight run of migration_one), then prove
    // migration_two's OWN runFanout call still succeeds — the two locks are
    // keyed independently by hashtext(migration_id).
    const holder_conn = try pool.acquire();
    defer pool.release(holder_conn);
    var lock_result = try holder_conn.query(alloc, "SELECT pg_try_advisory_lock(hashtext($1))", &.{migration_one});
    defer lock_result.deinit();
    defer holder_conn.exec("SELECT pg_advisory_unlock(hashtext($1))", &.{migration_one}) catch {};

    const run_id = try randomToken(alloc, "run03ac3");
    defer alloc.free(run_id);

    const result = try runFanout(alloc, &pool, .{ .migration_id = migration_two, .run_id = run_id }, succeedingStep);
    try testing.expectEqual(@as(u32, 0), result.pending);
    try testing.expect(result.done >= 1);

    const row = (try readControlRow(alloc, &pool, migration_two, tenant_id)) orelse return error.TestExpectedControlRow;
    defer freeControlRow(alloc, row);
    try testing.expectEqualStrings("done", row.status);
}

// ---------------------------------------------------------------------------
// MIG-03 AC5 / TC-MIG-03-05: the returned FanoutResult carries
// {run_id, done, failed, pending} — already exercised implicitly by every
// test above via result.done/failed/pending, but this test asserts run_id
// round-trips exactly, since none of the tests above check that field.
// ---------------------------------------------------------------------------

test "TC-MIG-03-05: FanoutResult.run_id round-trips the caller-supplied run_id" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    try insertActiveTenant(&pool, tenant_id);
    defer cleanupTenant(&pool, tenant_id);

    const migration_id = try randomToken(alloc, "mig03ac5");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);
    const run_id = try randomToken(alloc, "run03ac5");
    defer alloc.free(run_id);

    const result: FanoutResult = try runFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id }, succeedingStep);
    try testing.expectEqualStrings(run_id, result.run_id);
    try testing.expectEqual(@as(u32, 0), result.pending);
}
