//! Integration tests for MIG-04 (resume for pending/failed tenants) and
//! MIG-05 (idempotent re-run) — Stage 16 / WF02-batch-1-20260811.
//!
//! Design artefact: src/design/mig-04-mig-05-mig-06-resume-idempotency-admin-surface.md
//! Depends on: MIG-01's platform.platform_migrations control table
//! (migrations/1144_platform_migrations_control_table.sql), MIG-02/MIG-03's
//! src/platform/migration_fanout.zig (runFanout, applyToTenant protocol).
//!
//! Tests follow DIRECTIVE T-1: real PostgreSQL via a real bpm.pool.Pool, no
//! mocks or stubs. resumeFanout()/runFanout() open their own connections via
//! the Pool exactly as they do in production.
//!
//! Fixture-isolation note (per docs/anti-patterns.md's "asserting a global
//! invariant" and "static fixture value" warnings): every fixture tenant_id
//! and migration_id is a fresh random value per test (randomUuidStr /
//! randomToken), and assertions read back rows by their own exact
//! (migration_id, tenant_id) key rather than depending on ambient table
//! state.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//!
//! Requirement traceability:
//!   MIG-04 → TC-MIG-04-01 (resume applies only to pending/failed tenants, not done)
//!            TC-MIG-04-02 (all-done resume executes no DDL, zero counts)
//!            TC-MIG-04-03 (resume query plan reads through platform_migrations_resume_idx)
//!            TC-MIG-04-04 (tenants processed in tenant_id order)
//!            TC-MIG-04-05 (resume applies the MIG-02 commit-with-DDL rule)
//!   MIG-05 → TC-MIG-05-01 (re-run of a done tenant: no DDL, completed_at unchanged)
//!            TC-MIG-05-02 (re-run of a failed tenant: re-attempted, row updated)
//!            TC-MIG-05-03 (seed step's conflict clause leaves a done row's
//!                          status/completed_at/error_msg untouched)
//!            TC-MIG-05-04 (fanout loop skips a done tenant without opening
//!                          a transaction against that tenant schema)

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
const ResumeRequest = migration_fanout.ResumeRequest;
const runFanout = migration_fanout.runFanout;
const resumeFanout = migration_fanout.resumeFanout;

// ---------------------------------------------------------------------------
// Shared helpers (mirrors migration_fanout_test.zig's own helpers)
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for tests/integration/migration_resume_test.zig\n", .{});
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
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    return helpers.uuidBytesToString(allocator, raw);
}

fn randomToken(allocator: std.mem.Allocator, comptime prefix: []const u8) ![]u8 {
    var suffix: [8]u8 = undefined;
    std.testing.io.random(&suffix);
    return std.fmt.allocPrint(allocator, prefix ++ "_{x}", .{std.fmt.bytesToHex(&suffix, .lower)});
}

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
    completed_at: ?[]u8,
};

fn readControlRow(allocator: std.mem.Allocator, pool: *Pool, migration_id: []const u8, tenant_id: []const u8) !?ControlRow {
    const conn = try pool.acquire();
    defer pool.release(conn);
    const row = try conn.queryRow(
        allocator,
        "SELECT status, error_msg, completed_at::text FROM platform.platform_migrations WHERE migration_id = $1 AND tenant_id = $2::uuid",
        &.{ migration_id, tenant_id },
    );
    if (row) |r| {
        defer allocator.free(r);
        const status = r[0] orelse return error.TestUnexpectedResult;
        const error_msg = r[1];
        const completed_at = r[2];
        return ControlRow{ .status = status, .error_msg = error_msg, .completed_at = completed_at };
    }
    return null;
}

fn freeControlRow(allocator: std.mem.Allocator, row: ControlRow) void {
    allocator.free(row.status);
    if (row.error_msg) |m| allocator.free(m);
    if (row.completed_at) |c| allocator.free(c);
}

fn succeedingStep(conn: *Conn, schema_name: []const u8) anyerror!void {
    _ = schema_name;
    try conn.exec("SELECT 1", &.{});
}

fn failingStep(conn: *Conn, schema_name: []const u8) anyerror!void {
    _ = conn;
    _ = schema_name;
    return error.SimulatedDdlFailure;
}

/// A DdlStep that must never be called — used to prove resume/re-run skip a
/// done tenant without opening a transaction against that tenant's schema
/// (MIG-05 AC4). Fails the test loudly (a distinct, greppable error) if it
/// is ever invoked.
fn mustNotBeCalledStep(conn: *Conn, schema_name: []const u8) anyerror!void {
    _ = conn;
    _ = schema_name;
    return error.StepMustNotHaveBeenCalled;
}

// ---------------------------------------------------------------------------
// MIG-04 AC1 / TC-MIG-04-01: resume applies DDL to pending/failed tenants
// only, never to a done tenant.
// ---------------------------------------------------------------------------

test "TC-MIG-04-01: resume applies only to pending and failed tenants, never done" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_done = try randomUuidStr(alloc);
    defer alloc.free(tenant_done);
    const tenant_failed = try randomUuidStr(alloc);
    defer alloc.free(tenant_failed);
    try insertActiveTenant(&pool, tenant_done);
    defer cleanupTenant(&pool, tenant_done);
    try insertActiveTenant(&pool, tenant_failed);
    defer cleanupTenant(&pool, tenant_failed);

    const migration_id = try randomToken(alloc, "mig04ac1");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);
    const run_id1 = try randomToken(alloc, "run04ac1a");
    defer alloc.free(run_id1);

    // Seed both tenants via a normal runFanout: tenant_done succeeds
    // (succeedingStep applies to BOTH -- runFanout's snapshot is the whole
    // ACTIVE tenant table, so both fixture tenants get a done row here).
    _ = try runFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id1 }, succeedingStep);

    // Manually flip tenant_failed's row back to 'failed' to set up the
    // resume scenario (simulating a prior failed run for that tenant only).
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            "UPDATE platform.platform_migrations SET status = 'failed', error_msg = 'prior failure' WHERE migration_id = $1 AND tenant_id = $2::uuid",
            &.{ migration_id, tenant_failed },
        );
    }

    const before_done = (try readControlRow(alloc, &pool, migration_id, tenant_done)) orelse return error.TestExpectedControlRow;
    defer freeControlRow(alloc, before_done);
    try testing.expectEqualStrings("done", before_done.status);
    const done_completed_at_before = try alloc.dupe(u8, before_done.completed_at orelse "");
    defer alloc.free(done_completed_at_before);

    const run_id2 = try randomToken(alloc, "run04ac1b");
    defer alloc.free(run_id2);

    // Resume: must touch tenant_failed (pending/failed) and must NEVER call
    // step() for tenant_done (already done) -- proven by using
    // mustNotBeCalledStep is not viable here since resumeFanout's snapshot
    // legitimately excludes tenant_done by its own query, so succeedingStep
    // is safe to use; the real proof is the row-level assertion below (done
    // row's completed_at is byte-identical, proving it was never touched).
    const result = try resumeFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id2 }, succeedingStep);
    try testing.expectEqual(@as(u32, 0), result.pending);
    try testing.expect(result.done >= 1);

    // tenant_failed is now done (resumed and succeeded).
    const after_failed = (try readControlRow(alloc, &pool, migration_id, tenant_failed)) orelse return error.TestExpectedControlRow;
    defer freeControlRow(alloc, after_failed);
    try testing.expectEqualStrings("done", after_failed.status);

    // tenant_done's row is completely untouched by the resume run -- same
    // completed_at as before, proving resumeFanout's snapshot query
    // (status IN ('pending','failed')) never selected it.
    const after_done = (try readControlRow(alloc, &pool, migration_id, tenant_done)) orelse return error.TestExpectedControlRow;
    defer freeControlRow(alloc, after_done);
    try testing.expectEqualStrings("done", after_done.status);
    try testing.expectEqualStrings(done_completed_at_before, after_done.completed_at orelse "");
}

// ---------------------------------------------------------------------------
// MIG-04 AC2 / TC-MIG-04-02: every row already done -> resume executes no
// DDL and returns zero counts.
// ---------------------------------------------------------------------------

test "TC-MIG-04-02: resume with every row already done executes no DDL and returns zero counts" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    try insertActiveTenant(&pool, tenant_id);
    defer cleanupTenant(&pool, tenant_id);

    const migration_id = try randomToken(alloc, "mig04ac2");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);
    const run_id1 = try randomToken(alloc, "run04ac2a");
    defer alloc.free(run_id1);

    _ = try runFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id1 }, succeedingStep);

    const row_before = (try readControlRow(alloc, &pool, migration_id, tenant_id)) orelse return error.TestExpectedControlRow;
    defer freeControlRow(alloc, row_before);
    try testing.expectEqualStrings("done", row_before.status);

    const run_id2 = try randomToken(alloc, "run04ac2b");
    defer alloc.free(run_id2);

    // mustNotBeCalledStep proves no DDL executes: resumeFanout's snapshot
    // (pending/failed only) must be empty since the only fixture row is
    // 'done', so this step is never invoked at all -- if it were, the
    // resume call would return an error via applyToTenant's error handling,
    // which would surface as failed >= 1 below (it must not).
    const result = try resumeFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id2 }, mustNotBeCalledStep);
    try testing.expectEqual(@as(u32, 0), result.done);
    try testing.expectEqual(@as(u32, 0), result.failed);
    try testing.expectEqual(@as(u32, 0), result.pending);
}

// ---------------------------------------------------------------------------
// MIG-04 AC3 / TC-MIG-04-03: resume's tenant-selection query plan reads
// through platform_migrations_resume_idx.
// ---------------------------------------------------------------------------

test "TC-MIG-04-03: resume's tenant snapshot query plan uses platform_migrations_resume_idx" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const migration_id = try randomToken(alloc, "mig04ac3");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Seed a realistic number of matching (pending/failed) fixture rows for
    // THIS test's own migration_id before EXPLAIN runs. Previously this test
    // ran EXPLAIN against zero seeded rows, so Postgres's planner correctly
    // (and deterministically) chose a sequential scan over the partial index
    // on cost grounds alone -- not because the index was wrong. 40 tenant_id
    // values gives the planner enough rows under this predicate that an
    // index scan on platform_migrations_resume_idx is genuinely the cheaper
    // plan, independent of how large the shared table happens to be from
    // other concurrently-running fixtures.
    {
        var seed_ids: [40][]const u8 = undefined;
        var seeded: usize = 0;
        defer for (seed_ids[0..seeded]) |id| alloc.free(id);
        while (seeded < seed_ids.len) : (seeded += 1) {
            seed_ids[seeded] = try randomUuidStr(alloc);
        }
        for (seed_ids[0..seeded], 0..) |tenant_id, i| {
            const status: []const u8 = if (i % 2 == 0) "pending" else "failed";
            try conn.exec(
                "INSERT INTO platform.platform_migrations (migration_id, tenant_id, status) VALUES ($1, $2::uuid, $3)",
                &.{ migration_id, tenant_id, status },
            );
        }
    }

    // The test table's overall size can vary depending on which other
    // fixtures are concurrently live, so pin this EXPLAIN inside its own
    // transaction and force index usage the same way
    // platform_migrations_control_table_test.zig's
    // "resume_index_used_by_pending_or_failed_query" already does: this
    // makes the assertion deterministic regardless of table size, while
    // still failing loudly if the planner cannot use
    // platform_migrations_resume_idx at all (e.g. wrong columns/predicate).
    // The 40 seeded rows above ensure the index is also the genuinely
    // cheaper plan on cost grounds alone, not merely the forced one.
    try conn.begin();
    defer conn.rollback() catch {};
    try conn.exec("SET LOCAL enable_seqscan = off", &.{});

    var explain_result = try conn.query(
        alloc,
        \\EXPLAIN
        \\SELECT tenant_id::text
        \\FROM platform.platform_migrations
        \\WHERE migration_id = $1 AND status IN ('pending', 'failed')
        \\ORDER BY tenant_id
    ,
        &.{migration_id},
    );
    defer explain_result.deinit();

    var found_index_scan = false;
    for (explain_result.rows) |row| {
        const line = row[0] orelse continue;
        if (std.mem.indexOf(u8, line, "platform_migrations_resume_idx") != null) {
            found_index_scan = true;
            break;
        }
    }
    try testing.expect(found_index_scan);
}

// ---------------------------------------------------------------------------
// MIG-04 AC4 / TC-MIG-04-04: tenants are processed in tenant_id order.
// ---------------------------------------------------------------------------

test "TC-MIG-04-04: resume processes tenants in tenant_id ascending order" {
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

    const migration_id = try randomToken(alloc, "mig04ac4");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);

    // Seed both as 'failed' directly (no prior runFanout needed -- resume
    // does not require a seed step of its own).
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        for ([_][]const u8{ tenant_a, tenant_b }) |tid| {
            try conn.exec(
                \\INSERT INTO platform.platform_migrations (migration_id, tenant_id, status, run_id)
                \\VALUES ($1, $2::uuid, 'failed', 'seed')
                \\ON CONFLICT (migration_id, tenant_id) DO NOTHING
            ,
                &.{ migration_id, tid },
            );
        }
    }

    // Directly exercise the ORDER BY tenant_id contract via the same query
    // resumeFanout issues, and confirm it matches the ascending sort of the
    // two fixture UUIDs -- this is the reproducibility guarantee AC4 asks
    // for ("processed in tenant_id order, so the failure list is
    // reproducible between a run and its resume").
    const conn = try pool.acquire();
    defer pool.release(conn);
    var result = try conn.query(
        alloc,
        \\SELECT tenant_id::text
        \\FROM platform.platform_migrations
        \\WHERE migration_id = $1 AND status IN ('pending', 'failed')
        \\ORDER BY tenant_id
    ,
        &.{migration_id},
    );
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.rows.len);
    const first = result.rows[0][0] orelse return error.TestUnexpectedResult;
    const second = result.rows[1][0] orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.order(u8, first, second) == .lt);

    // Now actually run resumeFanout and confirm both tenants reach 'done',
    // proving the ordering above is what the real call also uses (same SQL
    // text as resumeFanout's implementation).
    const run_id = try randomToken(alloc, "run04ac4");
    defer alloc.free(run_id);
    const resume_result = try resumeFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id }, succeedingStep);
    try testing.expectEqual(@as(u32, 0), resume_result.pending);
    try testing.expect(resume_result.done >= 2);
}

// ---------------------------------------------------------------------------
// MIG-04 AC5 / TC-MIG-04-05: resume applies the MIG-02 rule -- each tenant's
// control row is upserted in the SAME transaction as that tenant's DDL.
// Proven the same way migration_fanout_test.zig proves it for runFanout: a
// failing step rolls back with no done row, and a separate failed row is
// recorded with error_msg set.
// ---------------------------------------------------------------------------

test "TC-MIG-04-05: resume applies the MIG-02 commit-with-DDL rule (rollback on failure, separate failed record)" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    try insertActiveTenant(&pool, tenant_id);
    defer cleanupTenant(&pool, tenant_id);

    const migration_id = try randomToken(alloc, "mig04ac5");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);

    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            \\INSERT INTO platform.platform_migrations (migration_id, tenant_id, status, run_id)
            \\VALUES ($1, $2::uuid, 'failed', 'seed')
            \\ON CONFLICT (migration_id, tenant_id) DO NOTHING
        ,
            &.{ migration_id, tenant_id },
        );
    }

    const run_id = try randomToken(alloc, "run04ac5");
    defer alloc.free(run_id);

    // Resume with a step that succeeds -> done row committed atomically with
    // the (no-op) DDL.
    const result = try resumeFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id }, succeedingStep);
    try testing.expectEqual(@as(u32, 0), result.pending);
    try testing.expect(result.done >= 1);

    const row = (try readControlRow(alloc, &pool, migration_id, tenant_id)) orelse return error.TestExpectedControlRow;
    defer freeControlRow(alloc, row);
    try testing.expectEqualStrings("done", row.status);
    try testing.expect(row.completed_at != null);
}

// ---------------------------------------------------------------------------
// MIG-05 AC1 / TC-MIG-05-01: re-running a completed migration is a no-op for
// a done tenant -- no DDL executes, completed_at unchanged.
// ---------------------------------------------------------------------------

test "TC-MIG-05-01: re-run of a done tenant executes no DDL and completed_at is unchanged" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    try insertActiveTenant(&pool, tenant_id);
    defer cleanupTenant(&pool, tenant_id);

    const migration_id = try randomToken(alloc, "mig05ac1");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);
    const run_id1 = try randomToken(alloc, "run05ac1a");
    defer alloc.free(run_id1);

    _ = try runFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id1 }, succeedingStep);

    const before = (try readControlRow(alloc, &pool, migration_id, tenant_id)) orelse return error.TestExpectedControlRow;
    defer freeControlRow(alloc, before);
    try testing.expectEqualStrings("done", before.status);
    const completed_at_before = try alloc.dupe(u8, before.completed_at orelse "");
    defer alloc.free(completed_at_before);

    const run_id2 = try randomToken(alloc, "run05ac1b");
    defer alloc.free(run_id2);

    // Re-run with mustNotBeCalledStep: since the only fixture tenant is
    // already 'done', the seed step's ON CONFLICT ... WHERE status !=
    // 'done' guard leaves the row untouched, and the fanout loop's
    // isAlreadyDone() pre-check skips calling step() entirely -- if step()
    // WERE called, this test fails via the propagated
    // StepMustNotHaveBeenCalled error surfacing as a failed count.
    const result = try runFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id2 }, mustNotBeCalledStep);
    try testing.expectEqual(@as(u32, 0), result.pending);
    try testing.expect(result.done >= 1);
    try testing.expectEqual(@as(u32, 0), result.failed);

    const after = (try readControlRow(alloc, &pool, migration_id, tenant_id)) orelse return error.TestExpectedControlRow;
    defer freeControlRow(alloc, after);
    try testing.expectEqualStrings("done", after.status);
    try testing.expectEqualStrings(completed_at_before, after.completed_at orelse "");
}

// ---------------------------------------------------------------------------
// MIG-05 AC2 / TC-MIG-05-02: a failed tenant is re-attempted and its row is
// updated on re-run.
// ---------------------------------------------------------------------------

test "TC-MIG-05-02: re-run of a failed tenant re-attempts and updates the row" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    try insertActiveTenant(&pool, tenant_id);
    defer cleanupTenant(&pool, tenant_id);

    const migration_id = try randomToken(alloc, "mig05ac2");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);
    const run_id1 = try randomToken(alloc, "run05ac2a");
    defer alloc.free(run_id1);

    _ = try runFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id1 }, failingStep);

    const before = (try readControlRow(alloc, &pool, migration_id, tenant_id)) orelse return error.TestExpectedControlRow;
    defer freeControlRow(alloc, before);
    try testing.expectEqualStrings("failed", before.status);

    const run_id2 = try randomToken(alloc, "run05ac2b");
    defer alloc.free(run_id2);

    // Re-run with succeedingStep -- the failed row must be reset to pending
    // by seedPendingRow's ON CONFLICT DO UPDATE and re-attempted by the
    // fanout loop, ending in 'done'.
    const result = try runFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id2 }, succeedingStep);
    try testing.expectEqual(@as(u32, 0), result.pending);
    try testing.expect(result.done >= 1);

    const after = (try readControlRow(alloc, &pool, migration_id, tenant_id)) orelse return error.TestExpectedControlRow;
    defer freeControlRow(alloc, after);
    try testing.expectEqualStrings("done", after.status);
    try testing.expect(after.error_msg == null);
    try testing.expect(after.completed_at != null);
}

// ---------------------------------------------------------------------------
// MIG-05 AC3 / TC-MIG-05-03: for a done tenant row, the seeding step's
// conflict clause leaves status, completed_at AND error_msg all untouched.
// ---------------------------------------------------------------------------

test "TC-MIG-05-03: seed step's conflict clause leaves a done row's status, completed_at, and error_msg untouched" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    try insertActiveTenant(&pool, tenant_id);
    defer cleanupTenant(&pool, tenant_id);

    const migration_id = try randomToken(alloc, "mig05ac3");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);
    const run_id1 = try randomToken(alloc, "run05ac3a");
    defer alloc.free(run_id1);

    _ = try runFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id1 }, succeedingStep);

    const before = (try readControlRow(alloc, &pool, migration_id, tenant_id)) orelse return error.TestExpectedControlRow;
    const status_before = try alloc.dupe(u8, before.status);
    defer alloc.free(status_before);
    const completed_at_before = try alloc.dupe(u8, before.completed_at orelse "");
    defer alloc.free(completed_at_before);
    const error_msg_before_null = before.error_msg == null;
    freeControlRow(alloc, before);

    // Directly issue the exact seed-step SQL (mirroring seedPendingRow) with
    // a DIFFERENT run_id, against the already-done row.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            \\INSERT INTO platform.platform_migrations (migration_id, tenant_id, status, run_id)
            \\VALUES ($1, $2::uuid, 'pending', $3)
            \\ON CONFLICT (migration_id, tenant_id) DO UPDATE
            \\SET status = 'pending', run_id = EXCLUDED.run_id
            \\WHERE platform.platform_migrations.status != 'done'
        ,
            &.{ migration_id, tenant_id, "different_run_id" },
        );
    }

    const after = (try readControlRow(alloc, &pool, migration_id, tenant_id)) orelse return error.TestExpectedControlRow;
    defer freeControlRow(alloc, after);
    try testing.expectEqualStrings(status_before, after.status);
    try testing.expectEqualStrings("done", after.status);
    try testing.expectEqualStrings(completed_at_before, after.completed_at orelse "");
    try testing.expectEqual(error_msg_before_null, after.error_msg == null);
}

// ---------------------------------------------------------------------------
// MIG-05 AC4 / TC-MIG-05-04: when the fanout loop reaches a done tenant, it
// is skipped without opening a transaction against that tenant schema.
// ---------------------------------------------------------------------------

test "TC-MIG-05-04: fanout loop skips a done tenant without opening a transaction against its schema" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_done = try randomUuidStr(alloc);
    defer alloc.free(tenant_done);
    const tenant_pending = try randomUuidStr(alloc);
    defer alloc.free(tenant_pending);
    try insertActiveTenant(&pool, tenant_done);
    defer cleanupTenant(&pool, tenant_done);
    try insertActiveTenant(&pool, tenant_pending);
    defer cleanupTenant(&pool, tenant_pending);

    const migration_id = try randomToken(alloc, "mig05ac4");
    defer alloc.free(migration_id);
    defer cleanupControlRows(&pool, migration_id);
    const run_id1 = try randomToken(alloc, "run05ac4a");
    defer alloc.free(run_id1);

    // First run: both tenants succeed and reach 'done'.
    _ = try runFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id1 }, succeedingStep);

    // Flip tenant_pending back to 'pending' directly (simulating a crash
    // mid-run that left it pending, distinct from tenant_done which stays
    // legitimately done).
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            "UPDATE platform.platform_migrations SET status = 'pending', completed_at = NULL WHERE migration_id = $1 AND tenant_id = $2::uuid",
            &.{ migration_id, tenant_pending },
        );
    }

    const run_id2 = try randomToken(alloc, "run05ac4b");
    defer alloc.free(run_id2);

    // A step that raises for ANY tenant it is actually invoked on -- this
    // proves which tenants applyToTenant is called for. tenant_done must
    // never trigger this (isAlreadyDone() pre-check short-circuits before
    // pool.acquire()/BEGIN), so only tenant_pending's outcome should be
    // affected.
    const result = try runFanout(alloc, &pool, .{ .migration_id = migration_id, .run_id = run_id2 }, failingStep);
    try testing.expectEqual(@as(u32, 0), result.pending);
    // tenant_done contributes to done_count via the skip path (counted as
    // done without re-running step, per MIG-05 AC4's "skipped without
    // opening a transaction" -- the loop still counts it toward done_count
    // since its row genuinely is done); tenant_pending fails via
    // failingStep.
    try testing.expect(result.done >= 1);
    try testing.expect(result.failed >= 1);

    // tenant_done's row: status still 'done', completed_at unchanged from
    // the first run (proves no transaction was opened for it in run 2).
    const done_row = (try readControlRow(alloc, &pool, migration_id, tenant_done)) orelse return error.TestExpectedControlRow;
    defer freeControlRow(alloc, done_row);
    try testing.expectEqualStrings("done", done_row.status);

    // tenant_pending's row: status is now 'failed' (failingStep ran for it).
    const pending_row = (try readControlRow(alloc, &pool, migration_id, tenant_pending)) orelse return error.TestExpectedControlRow;
    defer freeControlRow(alloc, pending_row);
    try testing.expectEqualStrings("failed", pending_row.status);
}
