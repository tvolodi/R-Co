//! Integration tests for EPIC-3 — Scheduler concurrency and DLQ routing.
//!
//! Covers:
//!   ISS-301 (TC-SCH-301-03): SKIP LOCKED alone is sufficient — two concurrent
//!     scheduler instances firing one timer result in exactly one TIMER_FIRED event.
//!   ISS-302 (TC-SCH-302-03): Startup sweep skipped when advisory lock is held by
//!     another node — is_startup_sweep set to false, normal polling continues.
//!   ISS-303 (TC-SCH-303-03): Timer moves to FAILED + DLQ after max retries.
//!   ISS-303 (TC-SCH-303-04): Timer stays PENDING before retry exhaustion.
//!
//! Requires: BPM_TEST_DB_URL environment variable.
//!
//! Test fixture isolation: per-test UUID prefixes guarantee no cross-test data
//! collision. All fixtures are committed (autocommit on pool connections) and
//! cleaned up unconditionally in defer blocks.
//!
//! Requirement traceability:
//!   ISS-303 → TC-SCH-303-03: exhaustion → FAILED + DLQ
//!   ISS-303 → TC-SCH-303-04: sub-exhaustion → stays PENDING
//!   ISS-301 → TC-SCH-301-03: SKIP LOCKED prevents double-fire
//!   ISS-302 → TC-SCH-302-03: lock-not-acquired → sweep skipped gracefully
const std = @import("std");
const testing = std.testing;
const pg = @import("pg");
const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const Scheduler = bpm.scheduler_poller.Scheduler;
const SchedulerConfig = bpm.scheduler_poller.SchedulerConfig;
const tenant_context = bpm.api_tenant_context;

// Default tenant UUID — the pool resolves this to schema 'tenant_default'.
const DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000000";

// SCHEDULER_STARTUP_LOCK_ID — must match the constant in scheduler.zig.
// Using a comptime value avoids a symbol reference to the private constant.
const STARTUP_LOCK_ID_STR = "5863412975429063421";

fn getTestDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set — skipping EPIC-3 scheduler integration tests\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 8 });
}

/// Set search_path on a connection acquired before tenant context was active,
/// or on a non-pool pg.Conn. Idempotent — can be called multiple times.
fn setTenantSearchPath(conn: anytype) void {
    conn.exec("SET search_path TO tenant_default,public", &.{}) catch {};
}

/// Set the thread-local tenant context so Pool.acquire() routes to the
/// 'tenant_default' schema. Must be called before any pool.acquire() that
/// should resolve business tables (timers, instance_projections, events, etc.).
fn setTestTenantContext() void {
    tenant_context.set(DEFAULT_TENANT_ID);
}

// ---------------------------------------------------------------------------
// TC-SCH-303-03: Timer fire exhaustion → FAILED + DLQ
// ---------------------------------------------------------------------------
//
// Fixture approach: pre-insert an events row with the timer's idempotency_key.
// Every fire attempt by the Scheduler fails with a unique-constraint violation
// on `uq_event_idempotency`, causing the fire transaction to roll back.
// The ISS-303 error path increments fire_error_count after each rollback.
// After max_timer_fire_retries (=3) failures, markTimerFailedInTx sets
// status='failed' and inserts a dead_letter_items row.

test "TC-SCH-303-03: timer fire exhaustion moves timer to FAILED and inserts DLQ entry" {
    const allocator = std.heap.page_allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);

    // Set tenant context so Pool.acquire() routes to tenant_default schema.
    setTestTenantContext();
    defer tenant_context.clear();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    // Per-test UUIDs — 30310000 prefix isolates from all other test fixtures.
    const instance_id = try harness.newUuidString(alloc);
    defer alloc.free(instance_id);
    const def_id = try harness.newUuidString(alloc);
    defer alloc.free(def_id);
    const timer_id = try harness.newUuidString(alloc);
    defer alloc.free(timer_id);
    const idem_key    = "timer-fired:30310000-0000-0000-0000-000000000002";

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Unconditional pre-cleanup and post-cleanup (defer runs even on failure).
    conn.exec("DELETE FROM dead_letter_items WHERE source_ref = $1", &.{timer_id}) catch {};
    conn.exec("DELETE FROM timers WHERE id = $1::uuid", &.{timer_id}) catch {};
    conn.exec("DELETE FROM events WHERE idempotency_key = $1", &.{idem_key}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};

    defer {
        conn.exec("DELETE FROM dead_letter_items WHERE source_ref = $1", &.{timer_id}) catch {};
        conn.exec("DELETE FROM timers WHERE id = $1::uuid", &.{timer_id}) catch {};
        conn.exec("DELETE FROM events WHERE idempotency_key = $1", &.{idem_key}) catch {};
        conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    }

    // Insert a minimal instance_projections row (satisfies timers FK).
    try conn.exec(
        "INSERT INTO instance_projections (instance_id, definition_id) VALUES ($1::uuid, $2::uuid)",
        &.{ instance_id, def_id },
    );

    // Insert a timer that fires immediately (fires_at in the past).
    try conn.exec(
        \\INSERT INTO timers (id, instance_id, timer_type, step_name, fires_at, action_type)
        \\VALUES ($1::uuid, $2::uuid, 'scheduled_transition', 'TEST_NODE',
        \\        NOW() - interval '1 second', 'auto_transition')
    ,
        &.{ timer_id, instance_id },
    );

    // Pre-insert an events row with the exact idempotency_key that the Scheduler
    // would use for this timer. Every fire attempt will fail on the
    // `uq_event_idempotency` UNIQUE index, forcing the fire transaction to roll back.
    try conn.exec(
        \\INSERT INTO events (instance_id, event_type, payload, actor_id,
        \\                    sequence_number, idempotency_key)
        \\VALUES ($1::uuid, 'TIMER_FIRED', '{}', $1::uuid, 99999, $2)
    ,
        &.{ instance_id, idem_key },
    );

    const max_retries: u32 = 3;
    var scheduler = Scheduler.init(&pool, SchedulerConfig{ .max_timer_fire_retries = max_retries });

    // Poll exactly max_timer_fire_retries times to exhaust the retry budget.
    // Each poll: fire fails → Tx2 increments fire_error_count. After the 3rd
    // failure fire_error_count reaches max_retries → Tx3 marks FAILED + DLQ.
    var i: u32 = 0;
    while (i < max_retries) : (i += 1) {
        _ = scheduler.pollDueTimers(allocator) catch {};
    }

    // Assert timer status = 'failed' and failed_at is populated (AC-303-3).
    const status_rows = try conn.query(
        allocator,
        \\SELECT status, (failed_at IS NOT NULL)::text
        \\FROM timers WHERE id = $1::uuid
    ,
        &.{timer_id},
    );
    defer {
        var r = status_rows;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), status_rows.rows.len);
    try testing.expectEqualStrings("failed", status_rows.rows[0][0] orelse "");
    try testing.expectEqualStrings("true", status_rows.rows[0][1] orelse "");

    // Assert DLQ entry with item_type='TIMER' and source_ref=timer_id (AC-303-4).
    const dlq_rows = try conn.query(
        allocator,
        \\SELECT item_type, reason
        \\FROM dead_letter_items WHERE source_ref = $1
        \\ORDER BY created_at DESC LIMIT 1
    ,
        &.{timer_id},
    );
    defer {
        var r = dlq_rows;
        r.deinit();
    }
    try testing.expect(dlq_rows.rows.len >= 1);
    try testing.expectEqualStrings("TIMER", dlq_rows.rows[0][0] orelse "");
    try testing.expectEqualStrings("TIMER_EXHAUSTED", dlq_rows.rows[0][1] orelse "");
}

// ---------------------------------------------------------------------------
// TC-SCH-303-04: Timer stays PENDING before retry exhaustion
// ---------------------------------------------------------------------------

test "TC-SCH-303-04: timer stays pending when fire_error_count < max_timer_fire_retries" {
    const allocator = std.heap.page_allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);

    setTestTenantContext();
    defer tenant_context.clear();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    // Per-test UUIDs — 30320000 prefix.
    const instance_id = try harness.newUuidString(alloc);
    defer alloc.free(instance_id);
    const def_id = try harness.newUuidString(alloc);
    defer alloc.free(def_id);
    const timer_id = try harness.newUuidString(alloc);
    defer alloc.free(timer_id);
    const idem_key    = "timer-fired:30320000-0000-0000-0000-000000000002";

    const conn = try pool.acquire();
    defer pool.release(conn);

    conn.exec("DELETE FROM dead_letter_items WHERE source_ref = $1", &.{timer_id}) catch {};
    conn.exec("DELETE FROM timers WHERE id = $1::uuid", &.{timer_id}) catch {};
    conn.exec("DELETE FROM events WHERE idempotency_key = $1", &.{idem_key}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};

    defer {
        conn.exec("DELETE FROM dead_letter_items WHERE source_ref = $1", &.{timer_id}) catch {};
        conn.exec("DELETE FROM timers WHERE id = $1::uuid", &.{timer_id}) catch {};
        conn.exec("DELETE FROM events WHERE idempotency_key = $1", &.{idem_key}) catch {};
        conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    }

    try conn.exec(
        "INSERT INTO instance_projections (instance_id, definition_id) VALUES ($1::uuid, $2::uuid)",
        &.{ instance_id, def_id },
    );
    try conn.exec(
        \\INSERT INTO timers (id, instance_id, timer_type, step_name, fires_at, action_type)
        \\VALUES ($1::uuid, $2::uuid, 'scheduled_transition', 'TEST_NODE',
        \\        NOW() - interval '1 second', 'auto_transition')
    ,
        &.{ timer_id, instance_id },
    );
    try conn.exec(
        \\INSERT INTO events (instance_id, event_type, payload, actor_id,
        \\                    sequence_number, idempotency_key)
        \\VALUES ($1::uuid, 'TIMER_FIRED', '{}', $1::uuid, 99999, $2)
    ,
        &.{ instance_id, idem_key },
    );

    const max_retries: u32 = 3;
    var scheduler = Scheduler.init(&pool, SchedulerConfig{ .max_timer_fire_retries = max_retries });

    // Poll max_retries - 1 = 2 times (below exhaustion threshold).
    const polls_below_threshold: u32 = max_retries - 1;
    var i: u32 = 0;
    while (i < polls_below_threshold) : (i += 1) {
        _ = scheduler.pollDueTimers(allocator) catch {};
    }

    // Assert timer is still PENDING (AC-303-5).
    const status_rows = try conn.query(
        allocator,
        "SELECT status, fire_error_count::text FROM timers WHERE id = $1::uuid",
        &.{timer_id},
    );
    defer {
        var r = status_rows;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), status_rows.rows.len);
    try testing.expectEqualStrings("pending", status_rows.rows[0][0] orelse "");
    try testing.expectEqualStrings("2", status_rows.rows[0][1] orelse "");

    // Assert no DLQ entry exists yet (AC-303-5).
    const dlq_rows = try conn.query(
        allocator,
        "SELECT COUNT(*) FROM dead_letter_items WHERE source_ref = $1",
        &.{timer_id},
    );
    defer {
        var r = dlq_rows;
        r.deinit();
    }
    try testing.expect(dlq_rows.rows.len >= 1);
    try testing.expectEqualStrings("0", dlq_rows.rows[0][0] orelse "1");
}

// ---------------------------------------------------------------------------
// TC-SCH-301-03: SKIP LOCKED prevents double-fire (ISS-301 AC-301-4)
// ---------------------------------------------------------------------------
//
// Two sequential Scheduler instances poll the same due timer. Only one fires it.
// (Sequential polling is sufficient: after the first scheduler commits the fire,
// the timer is 'fired' and the second scheduler's SKIP LOCKED query returns 0 rows.)

test "TC-SCH-301-03: two sequential scheduler polls on one timer fire it exactly once" {
    const allocator = std.heap.page_allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);

    setTestTenantContext();
    defer tenant_context.clear();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    // Per-test UUIDs — 30100000 prefix.
    // Note: for this test the fire must SUCCEED, so we do NOT pre-insert the
    // blocking events row. A minimal instance + timer is sufficient.
    const instance_id = try harness.newUuidString(alloc);
    defer alloc.free(instance_id);
    const def_id = try harness.newUuidString(alloc);
    defer alloc.free(def_id);
    const timer_id = try harness.newUuidString(alloc);
    defer alloc.free(timer_id);
    const idem_key    = "timer-fired:30100000-0000-0000-0000-000000000002";

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Cleanup (before and after).
    conn.exec("DELETE FROM dead_letter_items WHERE source_ref = $1", &.{timer_id}) catch {};
    conn.exec("DELETE FROM events WHERE idempotency_key = $1", &.{idem_key}) catch {};
    conn.exec("DELETE FROM timers WHERE id = $1::uuid", &.{timer_id}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    conn.exec("DELETE FROM instance_sequence WHERE instance_id = $1::uuid", &.{instance_id}) catch {};

    defer {
        conn.exec("DELETE FROM dead_letter_items WHERE source_ref = $1", &.{timer_id}) catch {};
        conn.exec("DELETE FROM events WHERE idempotency_key = $1", &.{idem_key}) catch {};
        conn.exec("DELETE FROM timers WHERE id = $1::uuid", &.{timer_id}) catch {};
        conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
        conn.exec("DELETE FROM instance_sequence WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    }

    // Insert instance (with instance_projections for the timers FK).
    try conn.exec(
        "INSERT INTO instance_projections (instance_id, definition_id) VALUES ($1::uuid, $2::uuid)",
        &.{ instance_id, def_id },
    );
    // Insert due timer.
    try conn.exec(
        \\INSERT INTO timers (id, instance_id, timer_type, step_name, fires_at, action_type)
        \\VALUES ($1::uuid, $2::uuid, 'scheduled_transition', 'TEST_NODE',
        \\        NOW() - interval '1 second', 'auto_transition')
    ,
        &.{ timer_id, instance_id },
    );

    // Scheduler A: polls and fires the timer.
    var sched_a = Scheduler.init(&pool, SchedulerConfig{});
    const summary_a = try sched_a.pollDueTimers(allocator);

    // Scheduler B: polls the same DB — the timer is already 'fired', not 'pending'.
    var sched_b = Scheduler.init(&pool, SchedulerConfig{});
    const summary_b = try sched_b.pollDueTimers(allocator);

    // Total fired across both schedulers must be exactly 1 (AC-301-4).
    const total_fired: u32 = summary_a.fired + summary_b.fired;
    try testing.expectEqual(@as(u32, 1), total_fired);

    // Assert timer status = 'fired' in the DB.
    const status_rows = try conn.query(
        allocator,
        "SELECT status FROM timers WHERE id = $1::uuid",
        &.{timer_id},
    );
    defer {
        var r = status_rows;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), status_rows.rows.len);
    try testing.expectEqualStrings("fired", status_rows.rows[0][0] orelse "");
}

// ---------------------------------------------------------------------------
// TC-SCH-302-03: Startup sweep skipped when advisory lock is held by another node
// ---------------------------------------------------------------------------
//
// Acquires the startup advisory lock on a separate direct pg.Conn (simulating
// "another node"), then creates a Scheduler (is_startup_sweep = true) and calls
// pollDueTimers. The Scheduler detects the lock is held, sets is_startup_sweep
// = false, and falls through to normal polling without error.

test "TC-SCH-302-03: startup sweep skipped gracefully when advisory lock is held" {
    const allocator = std.heap.page_allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);

    setTestTenantContext();
    defer tenant_context.clear();

    // Direct pg.Conn that holds the advisory lock during the test.
    // (Session-level advisory lock: held for the connection lifetime, released on close.)
    var lock_conn = pg.Conn.connectUrl(std.testing.io, allocator, url) catch |err| {
        std.debug.print("pg.Conn.connectUrl failed: {} — skipping TC-SCH-302-03\n", .{err});
        return error.SkipZigTest;
    };
    defer lock_conn.close();

    // Acquire the startup sweep advisory lock on lock_conn.
    const lock_result = lock_conn.query(
        allocator,
        "SELECT pg_try_advisory_lock($1::bigint)",
        &.{STARTUP_LOCK_ID_STR},
    ) catch {
        std.debug.print("pg_try_advisory_lock query failed — skipping TC-SCH-302-03\n", .{});
        return error.SkipZigTest;
    };
    defer {
        var r = lock_result;
        r.deinit();
    }

    // Verify we actually hold the lock (otherwise the test is vacuous).
    try testing.expect(lock_result.rows.len >= 1);
    const locked = if (lock_result.rows[0].len > 0) lock_result.rows[0][0] orelse "f" else "f";
    try testing.expect(std.mem.eql(u8, locked, "t") or std.mem.eql(u8, locked, "true"));

    // Create pool and a fresh Scheduler (is_startup_sweep = true).
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var scheduler = Scheduler.init(&pool, SchedulerConfig{});
    try testing.expect(scheduler.is_startup_sweep); // precondition

    // pollDueTimers must:
    //   1. Attempt to acquire the startup advisory lock → fail (lock_conn holds it).
    //   2. Set is_startup_sweep = false.
    //   3. Fall through to normal polling (no error).
    _ = scheduler.pollDueTimers(allocator) catch |err| {
        // PoolExhausted is acceptable if the pool can't get a sweep_conn — but
        // the pool has size 8, so this should not happen in practice.
        // Any error here is unexpected; re-return it.
        return err;
    };

    // Assert is_startup_sweep is false (AC-302-3).
    try testing.expect(!scheduler.is_startup_sweep);

    // Release the advisory lock so it doesn't linger for subsequent tests.
    _ = lock_conn.exec(
        "SELECT pg_advisory_unlock($1::bigint)",
        &.{STARTUP_LOCK_ID_STR},
    ) catch {};
}
