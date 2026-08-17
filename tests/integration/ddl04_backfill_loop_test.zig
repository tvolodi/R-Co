//! Integration tests for DDL-04 — the idempotent batched backfill loop
//! (src/platform/backfill.zig::runBackfill) against a real PostgreSQL table.
//!
//! Covers (see tests/specs/DDL-04.md for the full acceptance-criterion mapping):
//!   - DDL-04 AC1: a completed backfill re-runs to 0 updates with an identical
//!     end state; a partially-backfilled table resumes against the `IS NULL`
//!     predicate, skipping already-backfilled rows.
//!   - DDL-04 AC3: every batch commits (durability without an outer
//!     transaction) and no ROW EXCLUSIVE lock survives the run.
//!   - DDL-04 AC4: a batch over the timeout halves the next batch size
//!     (floor 500).
//!   - DDL-04 AC5: ten zero-progress iterations stop the loop and escalate with
//!     the remaining count (stall policy). Expected to FAIL against the current
//!     implementation — see the test body and the handoff issues.
//!   - DDL-04 AC6: the loop records cumulative per-batch progress into
//!     plat_migration_state (one row, upserted in place).
//!
//! runBackfill opens its OWN per-batch transactions on pool connections, so the
//! fixture table must be committed before the call (makePool pattern — same as
//! tests/integration/ordering_consumer_test.zig). The table name is derived from
//! a per-test UUID with dashes stripped (PostgreSQL identifiers + the module's
//! validateIdentifier allow [a-zA-Z0-9_]); the table is dropped and the
//! plat_migration_state row deleted in defer. Requires BPM_TEST_DB_URL (hard
//! failure if absent — never a silent skip). No module-level mutable state; no
//! error.SkipZigTest.

const std = @import("std");
const portable_env = @import("env");
const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const backfill = @import("platform_backfill");

/// Hard failure when BPM_TEST_DB_URL is absent — never a silent skip.
fn requireTestDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — cannot run DDL-04 backfill-loop integration tests against real PostgreSQL\n", .{});
            return error.MissingTestDbUrl;
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

const Fixtures = struct {
    table_name: []const u8,
    migration_id: []const u8,

    fn deinit(self: Fixtures, allocator: std.mem.Allocator) void {
        allocator.free(self.table_name);
        allocator.free(self.migration_id);
    }
};

fn cleanup(conn: *bpm.pool.Conn, fx: Fixtures) void {
    const drop_sql = std.fmt.allocPrint(std.heap.page_allocator, "DROP TABLE IF EXISTS {s}", .{fx.table_name}) catch return;
    defer std.heap.page_allocator.free(drop_sql);
    conn.exec(drop_sql, &.{}) catch {};
    conn.exec("DELETE FROM plat_migration_state WHERE migration_id = $1", &.{fx.migration_id}) catch {};
}

fn noDash(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| if (c != '-') try out.append(allocator, c);
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Create the fixture table (committed) and a per-test migration_id.
fn setupFixtures(allocator: std.mem.Allocator, conn: *bpm.pool.Conn) !Fixtures {
    const uuid = try bpm.uuid.newUuidV4(allocator);
    defer allocator.free(uuid);
    const suffix = try noDash(allocator, uuid);
    defer allocator.free(suffix);
    const table_name = try std.fmt.allocPrint(allocator, "ddl04_bf_{s}", .{suffix});
    errdefer allocator.free(table_name);
    const migration_id = try bpm.uuid.newUuidV4(allocator);
    errdefer allocator.free(migration_id);

    const create_sql = try std.fmt.allocPrint(allocator, "CREATE TABLE {s} (id bigint PRIMARY KEY, amount bigint, extra text)", .{table_name});
    defer allocator.free(create_sql);
    try conn.exec(create_sql, &.{});

    return Fixtures{ .table_name = table_name, .migration_id = migration_id };
}

/// Seed `count` rows with amount IS NULL (and extra set to a value that the
/// stalled-test predicate can exclude). Autocommitted via the pool conn.
fn seedNullRows(allocator: std.mem.Allocator, conn: *bpm.pool.Conn, fx: Fixtures, count: u64) !void {
    const insert_sql = try std.fmt.allocPrint(
        allocator,
        "INSERT INTO {s} (id, amount, extra) SELECT g, NULL, 'keep' FROM generate_series(1, {d}) g",
        .{ fx.table_name, count },
    );
    defer allocator.free(insert_sql);
    try conn.exec(insert_sql, &.{});
}

fn countNullRows(allocator: std.mem.Allocator, conn: *bpm.pool.Conn, fx: Fixtures) !i64 {
    const sql = try std.fmt.allocPrint(allocator, "SELECT count(*)::text FROM {s} WHERE amount IS NULL", .{fx.table_name});
    defer allocator.free(sql);
    var result = try conn.query(allocator, sql, &.{});
    defer result.deinit();
    if (result.rows.len == 0 or result.rows[0].len == 0 or result.rows[0][0] == null)
        return error.PersistenceFailed;
    return std.fmt.parseInt(i64, result.rows[0][0].?, 10) catch error.PersistenceFailed;
}

/// The canonical generated phase-2 statement (DDL-03's shape), with the
/// fixture table interpolated. `extra_guard` lets the stall test inject an
/// unsatisfiable extra WHERE condition.
fn generatedSql(allocator: std.mem.Allocator, fx: Fixtures, extra_guard: []const u8) ![]u8 {
    if (extra_guard.len == 0) {
        return std.fmt.allocPrint(
            allocator,
            "UPDATE {s} SET amount = 0 WHERE amount IS NULL AND ctid = ANY (ARRAY(SELECT ctid FROM {s} WHERE amount IS NULL LIMIT $1))",
            .{ fx.table_name, fx.table_name },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "UPDATE {s} SET amount = 0 WHERE amount IS NULL AND {s} AND ctid = ANY (ARRAY(SELECT ctid FROM {s} WHERE amount IS NULL AND {s} LIMIT $1))",
        .{ fx.table_name, extra_guard, fx.table_name, extra_guard },
    );
}

fn defaultConfig() backfill.BackfillConfig {
    return .{};
}

// ---------------------------------------------------------------------------
// AC1 — interrupt/resume idempotency
// ---------------------------------------------------------------------------

test "TC-DDL-04-AC1-full-run-then-rerun: a completed backfill re-runs to 0 updates with identical end state" {
    // covers: DDL-04
    const allocator = std.testing.allocator;
    const url = try requireTestDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);
    const fx = try setupFixtures(allocator, conn);
    defer fx.deinit(allocator);
    defer cleanup(conn, fx);

    try seedNullRows(allocator, conn, fx, 250);
    const sql = try generatedSql(allocator, fx, "");
    defer allocator.free(sql);
    const gb = backfill.GeneratedBackfill{
        .migration_id = fx.migration_id,
        .tenant_schema = "tenant_default",
        .table = fx.table_name,
        .column = "amount",
        .sql = sql,
        .order = 2,
    };

    // First run: backfills all 250 rows, end state complete.
    const first = try backfill.runBackfill(allocator, &pool, gb, defaultConfig());
    try std.testing.expectEqual(@as(i64, 250), first.rows_updated_total);
    try std.testing.expectEqual(@as(i64, 0), first.rows_remaining);
    try std.testing.expectEqual(false, first.stalled);
    try std.testing.expectEqual(backfill.MigrationPhaseStatus.applied, first.status);
    try std.testing.expectEqual(@as(i64, 0), try countNullRows(allocator, conn, fx));

    // Second (re-)run against the same IS NULL predicate: 0 updates, identical
    // end state — resume idempotency (AC1).
    const second = try backfill.runBackfill(allocator, &pool, gb, defaultConfig());
    try std.testing.expectEqual(@as(i64, 0), second.rows_updated_total);
    try std.testing.expectEqual(@as(i64, 0), second.rows_remaining);
    try std.testing.expectEqual(@as(i64, 0), try countNullRows(allocator, conn, fx));
}

test "TC-DDL-04-AC1-resume-partial: a partially-backfilled table resumes against IS NULL, skipping done rows" {
    // covers: DDL-04
    const allocator = std.testing.allocator;
    const url = try requireTestDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);
    const fx = try setupFixtures(allocator, conn);
    defer fx.deinit(allocator);
    defer cleanup(conn, fx);

    // 200 NULL rows; pre-backfill 50 (an interrupted run's already-done work).
    try seedNullRows(allocator, conn, fx, 200);
    const prefill_sql = try std.fmt.allocPrint(allocator, "UPDATE {s} SET amount = 0 WHERE id <= 50", .{fx.table_name});
    defer allocator.free(prefill_sql);
    try conn.exec(prefill_sql, &.{});
    // Interrupt record: RUNNING row with the interrupted run's cumulative count.
    try conn.exec(
        "INSERT INTO plat_migration_state (migration_id, tenant_schema, phase, status, attempt_count, rows_updated_total, rows_remaining) VALUES ($1, 'tenant_default', 'backfill', 'running', 1, 50, 150)",
        &.{fx.migration_id},
    );

    const sql = try generatedSql(allocator, fx, "");
    defer allocator.free(sql);
    const gb = backfill.GeneratedBackfill{
        .migration_id = fx.migration_id,
        .tenant_schema = "tenant_default",
        .table = fx.table_name,
        .column = "amount",
        .sql = sql,
        .order = 2,
    };

    // Resume: only the 150 remaining IS NULL rows are updated; end state equals
    // an uninterrupted run (all rows backfilled).
    const resumed = try backfill.runBackfill(allocator, &pool, gb, defaultConfig());
    try std.testing.expectEqual(@as(i64, 150), resumed.rows_updated_total);
    try std.testing.expectEqual(@as(i64, 0), resumed.rows_remaining);
    try std.testing.expectEqual(@as(i64, 0), try countNullRows(allocator, conn, fx));
}

// ---------------------------------------------------------------------------
// AC3 — per-batch commit, no transaction spans two batches
// ---------------------------------------------------------------------------

test "TC-DDL-04-AC3-per-batch-commit-durable: every batch commits and no ROW EXCLUSIVE lock survives the run" {
    // covers: DDL-04
    const allocator = std.testing.allocator;
    const url = try requireTestDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);
    const fx = try setupFixtures(allocator, conn);
    defer fx.deinit(allocator);
    defer cleanup(conn, fx);

    // 12000 rows with batch size 5000 -> batches of 5000, 5000, 2000, then 0.
    try seedNullRows(allocator, conn, fx, 12000);
    const sql = try generatedSql(allocator, fx, "");
    defer allocator.free(sql);
    const gb = backfill.GeneratedBackfill{
        .migration_id = fx.migration_id,
        .tenant_schema = "tenant_default",
        .table = fx.table_name,
        .column = "amount",
        .sql = sql,
        .order = 2,
    };

    const result = try backfill.runBackfill(allocator, &pool, gb, defaultConfig());
    try std.testing.expectEqual(@as(i64, 12000), result.rows_updated_total);
    try std.testing.expectEqual(@as(u64, 4), result.batches_run);

    // Durability: a fresh connection with NO outer transaction sees every batch
    // committed — each batch committed before the next began (AC3).
    try std.testing.expectEqual(@as(i64, 0), try countNullRows(allocator, conn, fx));

    // No ROW EXCLUSIVE lock on the table remains: the last batch's lock was
    // released at its COMMIT — no transaction spans two batches.
    const lock_sql = try std.fmt.allocPrint(
        allocator,
        "SELECT count(*)::text FROM pg_locks l JOIN pg_class c ON l.relation = c.oid WHERE c.relname = $1 AND l.locktype = 'relation' AND l.mode = 'RowExclusiveLock' AND l.granted",
        .{},
    );
    defer allocator.free(lock_sql);
    var lock_result = try conn.query(allocator, lock_sql, &.{fx.table_name});
    defer lock_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), lock_result.rows.len);
    try std.testing.expectEqualStrings("0", lock_result.rows[0][0] orelse "1");
}

// ---------------------------------------------------------------------------
// AC4 — adaptive halving on a slow batch
// ---------------------------------------------------------------------------

test "TC-DDL-04-AC4-halving: a batch over the timeout halves the next batch size" {
    // covers: DDL-04
    const allocator = std.testing.allocator;
    const url = try requireTestDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);
    const fx = try setupFixtures(allocator, conn);
    defer fx.deinit(allocator);
    defer cleanup(conn, fx);

    // 6000 rows, batch 5000: b1=5000 (halve->2500), b2=2500 (updates 1000;
    // halve->1250), b3=1250 (0 rows -> loop ends). final_batch_size = 1250 =
    // 5000 / 2^2 — halving fired on every slow batch.
    try seedNullRows(allocator, conn, fx, 6000);
    const sql = try generatedSql(allocator, fx, "");
    defer allocator.free(sql);
    const gb = backfill.GeneratedBackfill{
        .migration_id = fx.migration_id,
        .tenant_schema = "tenant_default",
        .table = fx.table_name,
        .column = "amount",
        .sql = sql,
        .order = 2,
    };

    const cfg = backfill.BackfillConfig{
        .backfill_batch_size = 5000,
        .batch_size_floor = 500,
        .batch_timeout_ms = 1, // any real batch exceeds 1 ms -> halve
        .stall_threshold_iterations = 10,
    };

    const result = try backfill.runBackfill(allocator, &pool, gb, cfg);
    try std.testing.expectEqual(@as(i64, 6000), result.rows_updated_total);
    try std.testing.expectEqual(@as(u32, 1250), result.final_batch_size);
}

// ---------------------------------------------------------------------------
// AC5 — stall policy (expected to fail against the current implementation)
// ---------------------------------------------------------------------------

test "TC-DDL-04-AC5-stall-escalation: ten zero-progress iterations stop the loop and escalate with the remaining count" {
    // covers: DDL-04
    const allocator = std.testing.allocator;
    const url = try requireTestDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);
    const fx = try setupFixtures(allocator, conn);
    defer fx.deinit(allocator);
    defer cleanup(conn, fx);

    // The batch statement's extra guard (`extra = 'never'`) can never match the
    // seeded rows (extra = 'keep'), so every batch updates 0 rows while
    // `count(*) WHERE amount IS NULL` stays > 0 — the stall signature.
    try seedNullRows(allocator, conn, fx, 100);
    const sql = try generatedSql(allocator, fx, "extra = 'never'");
    defer allocator.free(sql);
    const gb = backfill.GeneratedBackfill{
        .migration_id = fx.migration_id,
        .tenant_schema = "tenant_default",
        .table = fx.table_name,
        .column = "amount",
        .sql = sql,
        .order = 2,
    };

    const cfg = backfill.BackfillConfig{
        .backfill_batch_size = 5000,
        .batch_size_floor = 500,
        .stall_threshold_iterations = 2,
    };

    // AC5: the loop must stop with stalled=true, status=failed, and carry the
    // remaining IS NULL count so the caller escalates. NOTE: this test FAILS
    // against the current implementation because runBackfill executes
    // `if (rows_updated == 0) break;` BEFORE the stall check, making the stall
    // branch unreachable — filed as a BLOCKER defect in the handoff.
    const result = try backfill.runBackfill(allocator, &pool, gb, cfg);
    try std.testing.expectEqual(true, result.stalled);
    try std.testing.expectEqual(backfill.MigrationPhaseStatus.failed, result.status);
    try std.testing.expectEqual(@as(i64, 100), result.rows_remaining);
}

// ---------------------------------------------------------------------------
// AC6 — progress recorded into plat_migration_state
// ---------------------------------------------------------------------------

test "TC-DDL-04-AC6-loop-records-progress: the loop records cumulative counters into plat_migration_state" {
    // covers: DDL-04
    const allocator = std.testing.allocator;
    const url = try requireTestDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);
    const fx = try setupFixtures(allocator, conn);
    defer fx.deinit(allocator);
    defer cleanup(conn, fx);

    try seedNullRows(allocator, conn, fx, 12000);
    const sql = try generatedSql(allocator, fx, "");
    defer allocator.free(sql);
    const gb = backfill.GeneratedBackfill{
        .migration_id = fx.migration_id,
        .tenant_schema = "tenant_default",
        .table = fx.table_name,
        .column = "amount",
        .sql = sql,
        .order = 2,
    };

    _ = try backfill.runBackfill(allocator, &pool, gb, defaultConfig());

    // Exactly one progress row for (migration_id, tenant_schema, 'backfill')
    // with the cumulative counters — the AC6 in-place upsert (no second row).
    var rows = try conn.query(allocator,
        \\SELECT rows_updated_total::text, rows_remaining::text, last_batch_rows::text,
        \\       last_batch_ms::text, status, backfill_batch_size::text
        \\FROM plat_migration_state WHERE migration_id = $1 AND tenant_schema = 'tenant_default' AND phase = 'backfill'
    , &.{fx.migration_id});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    const row = rows.rows[0];
    try std.testing.expect(row.len >= 6);
    try std.testing.expectEqualStrings("12000", row[0] orelse "");
    try std.testing.expectEqualStrings("0", row[1] orelse "");
    try std.testing.expectEqualStrings("0", row[2] orelse ""); // final (zero) batch
    try std.testing.expectEqualStrings("applied", row[4] orelse "");
    try std.testing.expectEqualStrings("5000", row[5] orelse "");
}

test "TC-DDL-04-AC6b-persists-halved-batch-size: plat_migration_state records the adaptive batch size, not the initial default" {
    // covers: DDL-04 (ISS-0716 — adaptive backfill_batch_size must be persisted)
    const allocator = std.testing.allocator;
    const url = try requireTestDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);
    const fx = try setupFixtures(allocator, conn);
    defer fx.deinit(allocator);
    defer cleanup(conn, fx);

    // 6000 rows; batch_size 5000, batch_timeout_ms 1 (every real batch exceeds
    // 1 ms): iter 1 uses size 5000 -> halves to 2500; iter 2 uses 2500 ->
    // halves to 1250; iter 3 uses 1250, 0 updates, exits.
    // The terminal status write must persist backfill_batch_size = 1250, NOT
    // the initial default 5000.  Pre-fix recordBatchProgress hardcoded 5000;
    // this assertion distinguishes pre-fix from post-fix.
    try seedNullRows(allocator, conn, fx, 6000);
    const sql = try generatedSql(allocator, fx, "");
    defer allocator.free(sql);
    const gb = backfill.GeneratedBackfill{
        .migration_id = fx.migration_id,
        .tenant_schema = "tenant_default",
        .table = fx.table_name,
        .column = "amount",
        .sql = sql,
        .order = 2,
    };

    const cfg = backfill.BackfillConfig{
        .backfill_batch_size = 5000,
        .batch_size_floor = 500,
        .batch_timeout_ms = 1,
        .stall_threshold_iterations = 10,
    };

    const result = try backfill.runBackfill(allocator, &pool, gb, cfg);
    try std.testing.expectEqual(@as(i64, 6000), result.rows_updated_total);
    try std.testing.expectEqual(@as(u32, 1250), result.final_batch_size);

    // The persisted backfill_batch_size must reflect the halved final value
    // (1250), not the initial config value (5000).
    var rows = try conn.query(allocator,
        \\SELECT backfill_batch_size::text, status
        \\FROM plat_migration_state
        \\WHERE migration_id = $1 AND tenant_schema = 'tenant_default' AND phase = 'backfill'
    , &.{fx.migration_id});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    const row = rows.rows[0];
    try std.testing.expect(row.len >= 2);
    try std.testing.expectEqualStrings("1250", row[0] orelse "");
    try std.testing.expectEqualStrings("applied", row[1] orelse "");
}
