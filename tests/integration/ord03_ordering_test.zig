//! Integration tests for ORD-03 — sequence order guard, cursor advance, and
//! gap sweeping (src/ordering/cursor.zig, consumer.zig, sweeper.zig).
//!
//! Covers (see tests/specs/ORD-03.md for the full acceptance-criterion mapping):
//!   - ORD-03 AC1: out-of-order completion (seq 6 before 5) -> ApplyOutcome.deferred,
//!     silent rollback, row stays PENDING, no event.
//!   - ORD-03 AC2: seq 5 then 6 applied in order; applied_seq advances; engine
//!     observes 5 before 6 (EXECUTION_EFFECT_APPLIED events ordered).
//!   - ORD-03 AC3: the conditional cursor advance returns 0 on a stale
//!     precondition (CursorRaceLost) and a double-apply is impossible.
//!   - ORD-03 AC4: a typed apply failure -> ApplyOutcome.apply_failed; rollback
//!     leaves applied state and applied_seq un-diverged.
//!   - ORD-03 AC5: the gap sweeper moves every PENDING row of a stalled
//!     correlation to DEAD as one unit; a slow-but-present correlation is not
//!     swept.
//!   - ORD-03 AC6: recordCompletion's ON CONFLICT DO NOTHING absorbs a
//!     re-inserted (correlation_id, sequence_no).
//!
//! Requires: BPM_TEST_DB_URL environment variable — the test FAILS loudly (it
//! does not silently skip) when the variable is absent, per the TEST-DESIGNER
//! self-sufficiency rule.
//!
//! Fixture isolation: per-test UUID correlation ids, seeded and cleaned up
//! through a real bpm.pool.Pool (committed fixtures are required for genuine
//! cross-connection cursor/apply semantics — TestHarness's single rolled-back
//! transaction cannot see its own writes from a second connection). No
//! module-level mutable state; no error.SkipZigTest.

const std = @import("std");
const portable_env = @import("env");
const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const ordering_mod = @import("ordering_mod");
const cursor = @import("ordering_cursor");
const consumer = @import("ordering_consumer");
const sweeper = @import("ordering_sweeper");

/// Hard failure when BPM_TEST_DB_URL is absent — never a silent skip.
fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — cannot run ORD-03 integration tests against real PostgreSQL\n", .{});
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
    correlation_x: []const u8,
    correlation_y: []const u8,

    fn init(allocator: std.mem.Allocator) !Fixtures {
        return Fixtures{
            .correlation_x = try bpm.uuid.newUuidV4(allocator),
            .correlation_y = try bpm.uuid.newUuidV4(allocator),
        };
    }

    fn deinit(self: Fixtures, allocator: std.mem.Allocator) void {
        allocator.free(self.correlation_x);
        allocator.free(self.correlation_y);
    }
};

fn cleanup(allocator: std.mem.Allocator, conn: *bpm.pool.Conn, fx: Fixtures) void {
    conn.exec("DELETE FROM plat_effect_completion WHERE correlation_id = $1", &.{fx.correlation_x}) catch {};
    conn.exec("DELETE FROM plat_effect_completion WHERE correlation_id = $1", &.{fx.correlation_y}) catch {};
    conn.exec("DELETE FROM plat_correlation_cursor WHERE correlation_id = $1", &.{fx.correlation_x}) catch {};
    conn.exec("DELETE FROM plat_correlation_cursor WHERE correlation_id = $1", &.{fx.correlation_y}) catch {};
    // EXECUTION_EFFECT_APPLIED events carry the correlation_id in their JSONB
    // payload. Delete only this test's own events (per-test UUID, so the LIKE
    // pattern is specific and can never touch another test's rows).
    const pat_x = std.fmt.allocPrint(allocator, "%{s}%", .{fx.correlation_x}) catch return;
    defer allocator.free(pat_x);
    conn.exec("DELETE FROM events WHERE event_type = 'EXECUTION_EFFECT_APPLIED' AND payload::text LIKE $1", &.{pat_x}) catch {};
    const pat_y = std.fmt.allocPrint(allocator, "%{s}%", .{fx.correlation_y}) catch return;
    defer allocator.free(pat_y);
    conn.exec("DELETE FROM events WHERE event_type = 'EXECUTION_EFFECT_APPLIED' AND payload::text LIKE $1", &.{pat_y}) catch {};
}

/// Seed a PENDING completion row (autocommitted) and return its completion_id.
fn seedCompletion(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    correlation_id: []const u8,
    sequence_no: i64,
) ![]u8 {
    const seq_text = try std.fmt.allocPrint(allocator, "{d}", .{sequence_no});
    defer allocator.free(seq_text);
    try conn.exec(
        "INSERT INTO plat_effect_completion (correlation_id, sequence_no, status, payload, received_at) VALUES ($1, $2, 'PENDING', '{}'::jsonb, now())",
        &.{ correlation_id, seq_text },
    );
    var result = try conn.query(
        allocator,
        "SELECT completion_id::text FROM plat_effect_completion WHERE correlation_id = $1 AND sequence_no = $2",
        &.{ correlation_id, seq_text },
    );
    defer result.deinit();
    if (result.rows.len == 0 or result.rows[0].len == 0 or result.rows[0][0] == null)
        return error.PersistenceFailed;
    return allocator.dupe(u8, result.rows[0][0].?);
}

/// Seed an old PENDING completion (received_at in the past) — used by AC5.
fn seedOldCompletion(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    correlation_id: []const u8,
    sequence_no: i64,
) ![]u8 {
    const seq_text = try std.fmt.allocPrint(allocator, "{d}", .{sequence_no});
    defer allocator.free(seq_text);
    try conn.exec(
        "INSERT INTO plat_effect_completion (correlation_id, sequence_no, status, payload, received_at) VALUES ($1, $2, 'PENDING', '{}'::jsonb, now() - interval '1 minute')",
        &.{ correlation_id, seq_text },
    );
    var result = try conn.query(
        allocator,
        "SELECT completion_id::text FROM plat_effect_completion WHERE correlation_id = $1 AND sequence_no = $2",
        &.{ correlation_id, seq_text },
    );
    defer result.deinit();
    if (result.rows.len == 0 or result.rows[0].len == 0 or result.rows[0][0] == null)
        return error.PersistenceFailed;
    return allocator.dupe(u8, result.rows[0][0].?);
}

fn seedCursor(allocator: std.mem.Allocator, conn: *bpm.pool.Conn, correlation_id: []const u8, applied_seq: i64) !void {
    const seq_text = try std.fmt.allocPrint(allocator, "{d}", .{applied_seq});
    defer allocator.free(seq_text);
    try conn.exec(
        "INSERT INTO plat_correlation_cursor (correlation_id, applied_seq) VALUES ($1, $2) ON CONFLICT (correlation_id) DO UPDATE SET applied_seq = EXCLUDED.applied_seq",
        &.{ correlation_id, seq_text },
    );
}

fn readAppliedSeq(allocator: std.mem.Allocator, conn: *bpm.pool.Conn, correlation_id: []const u8) !i64 {
    var result = try conn.query(
        allocator,
        "SELECT applied_seq::text FROM plat_correlation_cursor WHERE correlation_id = $1",
        &.{correlation_id},
    );
    defer result.deinit();
    if (result.rows.len == 0 or result.rows[0].len == 0 or result.rows[0][0] == null)
        return error.PersistenceFailed;
    return std.fmt.parseInt(i64, result.rows[0][0].?, 10) catch error.PersistenceFailed;
}

fn readCompletionStatus(allocator: std.mem.Allocator, conn: *bpm.pool.Conn, completion_id: []const u8) ![]u8 {
    var result = try conn.query(
        allocator,
        "SELECT status FROM plat_effect_completion WHERE completion_id = $1::uuid",
        &.{completion_id},
    );
    defer result.deinit();
    if (result.rows.len == 0 or result.rows[0].len == 0 or result.rows[0][0] == null)
        return error.PersistenceFailed;
    return allocator.dupe(u8, result.rows[0][0].?);
}

fn countEffectAppliedEvents(allocator: std.mem.Allocator, conn: *bpm.pool.Conn, correlation_id: []const u8) !u64 {
    const pattern = try std.fmt.allocPrint(allocator, "%{s}%", .{correlation_id});
    defer allocator.free(pattern);
    var result = try conn.query(
        allocator,
        "SELECT count(*) FROM events WHERE event_type = 'EXECUTION_EFFECT_APPLIED' AND payload::text LIKE $1",
        &.{pattern},
    );
    defer result.deinit();
    if (result.rows.len == 0 or result.rows[0].len == 0 or result.rows[0][0] == null)
        return error.PersistenceFailed;
    return std.fmt.parseInt(u64, result.rows[0][0].?, 10) catch error.PersistenceFailed;
}

// ---------------------------------------------------------------------------
// AC0 helper — readOrInitCursor (MissingCursorRow recovery)
// ---------------------------------------------------------------------------

test "TC-ORD-03-AC0-read-or-init-cursor: a missing cursor row is inserted at applied_seq 0" {
    // covers: ORD-03
    const allocator = std.testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const fx = try Fixtures.init(allocator);
    defer fx.deinit(allocator);
    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanup(allocator, conn, fx);

    // No cursor row for correlation_x yet.
    const seq = try cursor.readOrInitCursor(allocator, conn, fx.correlation_x);
    try std.testing.expectEqual(@as(i64, 0), seq);

    const reread = try readAppliedSeq(allocator, conn, fx.correlation_x);
    try std.testing.expectEqual(@as(i64, 0), reread);
}

// ---------------------------------------------------------------------------
// AC1 — out-of-order silent rollback
// ---------------------------------------------------------------------------

test "TC-ORD-03-AC1-out-of-order-deferred: sequence 6 before 5 is not applied and stays PENDING" {
    // covers: ORD-03
    const allocator = std.testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const fx = try Fixtures.init(allocator);
    defer fx.deinit(allocator);
    const seed = try pool.acquire();
    defer pool.release(seed);
    defer cleanup(allocator, seed, fx);

    // applied_seq = 4; completion for sequence 6 arrives before 5.
    try seedCursor(allocator, seed, fx.correlation_x, 4);
    const completion_id = try seedCompletion(allocator, seed, fx.correlation_x, 6);
    defer allocator.free(completion_id);

    const claim = ordering_mod.ClaimedCompletion{
        .completion_id = try allocator.dupe(u8, completion_id),
        .correlation_id = try allocator.dupe(u8, fx.correlation_x),
        .sequence_no = 6,
    };
    defer claim.deinit(allocator);

    const apply_conn = try pool.acquire();
    defer pool.release(apply_conn);
    try apply_conn.begin();
    const outcome = try consumer.applyCompletion(allocator, apply_conn, claim);
    // AC1: silent rollback with no error; the caller rolls back.
    try std.testing.expectEqual(consumer.ApplyOutcome.deferred, outcome);
    apply_conn.rollback() catch {};

    // Row stays PENDING; cursor unchanged at 4; no event appended.
    const status = try readCompletionStatus(allocator, seed, completion_id);
    defer allocator.free(status);
    try std.testing.expectEqualStrings("PENDING", status);
    const applied = try readAppliedSeq(allocator, seed, fx.correlation_x);
    try std.testing.expectEqual(@as(i64, 4), applied);
    const events = try countEffectAppliedEvents(allocator, seed, fx.correlation_x);
    try std.testing.expectEqual(@as(u64, 0), events);
}

// ---------------------------------------------------------------------------
// AC2 — ordered apply advances the cursor and the engine observes 5 before 6
// ---------------------------------------------------------------------------

test "TC-ORD-03-AC2-ordered-apply-advances-cursor: seq 5 then 6 applied in order" {
    // covers: ORD-03
    const allocator = std.testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const fx = try Fixtures.init(allocator);
    defer fx.deinit(allocator);
    const seed = try pool.acquire();
    defer pool.release(seed);
    defer cleanup(allocator, seed, fx);

    try seedCursor(allocator, seed, fx.correlation_x, 4);
    const id5 = try seedCompletion(allocator, seed, fx.correlation_x, 5);
    defer allocator.free(id5);
    const id6 = try seedCompletion(allocator, seed, fx.correlation_x, 6);
    defer allocator.free(id6);

    // Apply seq 5 (next in order).
    {
        const claim5 = ordering_mod.ClaimedCompletion{
            .completion_id = try allocator.dupe(u8, id5),
            .correlation_id = try allocator.dupe(u8, fx.correlation_x),
            .sequence_no = 5,
        };
        defer claim5.deinit(allocator);
        const apply_conn = try pool.acquire();
        defer pool.release(apply_conn);
        try apply_conn.begin();
        const outcome = try consumer.applyCompletion(allocator, apply_conn, claim5);
        try std.testing.expectEqual(consumer.ApplyOutcome.applied, outcome);
        try apply_conn.commit();
    }

    // Cursor advanced to 5; row APPLIED; one EXECUTION_EFFECT_APPLIED event.
    try std.testing.expectEqual(@as(i64, 5), try readAppliedSeq(allocator, seed, fx.correlation_x));
    const status5 = try readCompletionStatus(allocator, seed, id5);
    defer allocator.free(status5);
    try std.testing.expectEqualStrings("APPLIED", status5);
    try std.testing.expectEqual(@as(u64, 1), try countEffectAppliedEvents(allocator, seed, fx.correlation_x));

    // Apply seq 6 next — the order guard admits it because applied_seq is now 5.
    {
        const claim6 = ordering_mod.ClaimedCompletion{
            .completion_id = try allocator.dupe(u8, id6),
            .correlation_id = try allocator.dupe(u8, fx.correlation_x),
            .sequence_no = 6,
        };
        defer claim6.deinit(allocator);
        const apply_conn = try pool.acquire();
        defer pool.release(apply_conn);
        try apply_conn.begin();
        const outcome = try consumer.applyCompletion(allocator, apply_conn, claim6);
        try std.testing.expectEqual(consumer.ApplyOutcome.applied, outcome);
        try apply_conn.commit();
    }

    try std.testing.expectEqual(@as(i64, 6), try readAppliedSeq(allocator, seed, fx.correlation_x));
    const status6 = try readCompletionStatus(allocator, seed, id6);
    defer allocator.free(status6);
    try std.testing.expectEqualStrings("APPLIED", status6);
    // Two events now: sequence 5 appended before sequence 6 (engine observes order).
    try std.testing.expectEqual(@as(u64, 2), try countEffectAppliedEvents(allocator, seed, fx.correlation_x));
}

// ---------------------------------------------------------------------------
// AC3 — conditional cursor advance (0 rows) and double-apply guard
// ---------------------------------------------------------------------------

test "TC-ORD-03-AC3-cursor-race-0-rows: the conditional advance returns 0 on a stale cursor" {
    // covers: ORD-03
    const allocator = std.testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const fx = try Fixtures.init(allocator);
    defer fx.deinit(allocator);
    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanup(allocator, conn, fx);

    try seedCursor(allocator, conn, fx.correlation_x, 4);

    // Stale caller first: a caller who read applied_seq = 4 tries to advance to
    // 6 (precondition applied_seq = 5) while the cursor is still 4 -> 0 rows.
    // The conditional WHERE applied_seq = $2 - 1 makes a mis-advance impossible.
    const advanced_stale = try cursor.advanceCursor(allocator, conn, fx.correlation_x, 6);
    try std.testing.expectEqual(@as(u64, 0), advanced_stale);
    try std.testing.expectEqual(@as(i64, 4), try readAppliedSeq(allocator, conn, fx.correlation_x));

    // Valid advance: applied_seq 4 -> 5 (precondition applied_seq = 4 matches).
    const advanced_ok = try cursor.advanceCursor(allocator, conn, fx.correlation_x, 5);
    try std.testing.expectEqual(@as(u64, 1), advanced_ok);
    try std.testing.expectEqual(@as(i64, 5), try readAppliedSeq(allocator, conn, fx.correlation_x));
}

test "TC-ORD-03-AC3-double-apply-guard: re-applying an already-applied sequence is deferred" {
    // covers: ORD-03
    const allocator = std.testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const fx = try Fixtures.init(allocator);
    defer fx.deinit(allocator);
    const seed = try pool.acquire();
    defer pool.release(seed);
    defer cleanup(allocator, seed, fx);

    // Simulate "seq 5 already applied, cursor at 5" then a re-claim of seq 5.
    try seedCursor(allocator, seed, fx.correlation_x, 5);
    const id5 = try seedCompletion(allocator, seed, fx.correlation_x, 5);
    defer allocator.free(id5);
    try seed.exec(
        "UPDATE plat_effect_completion SET status = 'APPLIED' WHERE completion_id = $1::uuid",
        &.{id5},
    );

    const claim5 = ordering_mod.ClaimedCompletion{
        .completion_id = try allocator.dupe(u8, id5),
        .correlation_id = try allocator.dupe(u8, fx.correlation_x),
        .sequence_no = 5,
    };
    defer claim5.deinit(allocator);

    const apply_conn = try pool.acquire();
    defer pool.release(apply_conn);
    try apply_conn.begin();
    const outcome = try consumer.applyCompletion(allocator, apply_conn, claim5);
    // 5 != 5 + 1 -> order guard defers; a double-apply is impossible.
    try std.testing.expectEqual(consumer.ApplyOutcome.deferred, outcome);
    apply_conn.rollback() catch {};
    try std.testing.expectEqual(@as(i64, 5), try readAppliedSeq(allocator, seed, fx.correlation_x));
}

// ---------------------------------------------------------------------------
// AC4 — typed apply failure rolls back state and cursor together
// ---------------------------------------------------------------------------

test "TC-ORD-03-AC4-apply-failed-rollback: a typed apply failure cannot diverge state and cursor" {
    // covers: ORD-03
    const allocator = std.testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const fx = try Fixtures.init(allocator);
    defer fx.deinit(allocator);
    const seed = try pool.acquire();
    defer pool.release(seed);
    defer cleanup(allocator, seed, fx);

    try seedCursor(allocator, seed, fx.correlation_x, 4);
    const id5 = try seedCompletion(allocator, seed, fx.correlation_x, 5);
    defer allocator.free(id5);

    // A claim whose completion_id is malformed forces the apply's
    // `completion_id = $1::uuid` cast to fail (SQLSTATE 22P02) — a typed apply
    // error that must roll back the whole transaction (AC4).
    const claim_bad = ordering_mod.ClaimedCompletion{
        .completion_id = try allocator.dupe(u8, "not-a-valid-uuid"),
        .correlation_id = try allocator.dupe(u8, fx.correlation_x),
        .sequence_no = 5,
    };
    defer claim_bad.deinit(allocator);

    const apply_conn = try pool.acquire();
    defer pool.release(apply_conn);
    try apply_conn.begin();
    const outcome = try consumer.applyCompletion(allocator, apply_conn, claim_bad);
    try std.testing.expectEqual(consumer.ApplyOutcome.apply_failed, outcome);
    apply_conn.rollback() catch {};

    // After the rollback: row still PENDING, cursor still 4, no event — applied
    // state and applied_seq cannot diverge.
    const status = try readCompletionStatus(allocator, seed, id5);
    defer allocator.free(status);
    try std.testing.expectEqualStrings("PENDING", status);
    try std.testing.expectEqual(@as(i64, 4), try readAppliedSeq(allocator, seed, fx.correlation_x));
    try std.testing.expectEqual(@as(u64, 0), try countEffectAppliedEvents(allocator, seed, fx.correlation_x));
}

// ---------------------------------------------------------------------------
// AC5 — gap sweeper: DEAD transition as one unit; non-stalled left alone
// ---------------------------------------------------------------------------

test "TC-ORD-03-AC5-sweep-stalled-to-dead: a stalled correlation is swept to DEAD as one unit" {
    // covers: ORD-03
    const allocator = std.testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const fx = try Fixtures.init(allocator);
    defer fx.deinit(allocator);
    const seed = try pool.acquire();
    defer pool.release(seed);
    defer cleanup(allocator, seed, fx);

    // Correlation X: applied_seq=1, PENDING at 3 and 4 (predecessor seq 2
    // absent), both older than the gap timeout -> genuinely stalled.
    try seedCursor(allocator, seed, fx.correlation_x, 1);
    const x3 = try seedOldCompletion(allocator, seed, fx.correlation_x, 3);
    defer allocator.free(x3);
    const x4 = try seedOldCompletion(allocator, seed, fx.correlation_x, 4);
    defer allocator.free(x4);

    const sweep_conn = try pool.acquire();
    defer pool.release(sweep_conn);

    const swept = try sweeper.sweepStalledCorrelations(allocator, sweep_conn, 5);
    defer {
        for (swept) |s| s.deinit(allocator);
        allocator.free(swept);
    }

    // Exactly one swept correlation: X, with both unapplied sequence nos.
    try std.testing.expectEqual(@as(usize, 1), swept.len);
    try std.testing.expectEqualStrings(fx.correlation_x, swept[0].correlation_id);
    try std.testing.expectEqual(@as(u64, 2), swept[0].pending_row_count);
    try std.testing.expectEqual(@as(usize, 2), swept[0].unapplied_sequence_nos.len);
    try std.testing.expectEqual(@as(i64, 3), swept[0].unapplied_sequence_nos[0]);
    try std.testing.expectEqual(@as(i64, 4), swept[0].unapplied_sequence_nos[1]);

    // Every PENDING row of X moved to DEAD (one transaction; nothing half-applied).
    const dead_count = try connCount(allocator, seed, "SELECT count(*) FROM plat_effect_completion WHERE correlation_id = $1 AND status = 'DEAD'", &.{fx.correlation_x});
    try std.testing.expectEqual(@as(u64, 2), dead_count);
    const pending_left = try connCount(allocator, seed, "SELECT count(*) FROM plat_effect_completion WHERE correlation_id = $1 AND status = 'PENDING'", &.{fx.correlation_x});
    try std.testing.expectEqual(@as(u64, 0), pending_left);
}

test "TC-ORD-03-AC5-non-stalled-not-swept: a slow-but-present predecessor is not dead-lettered" {
    // covers: ORD-03
    const allocator = std.testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const fx = try Fixtures.init(allocator);
    defer fx.deinit(allocator);
    const seed = try pool.acquire();
    defer pool.release(seed);
    defer cleanup(allocator, seed, fx);

    // Correlation Y: applied_seq=2, PENDING at 3 (predecessor seq 2 present —
    // applied) and 5, both old. Y's lowest PENDING sequence is exactly
    // applied_seq + 1, so it is merely behind, not gapped; it must NOT be swept.
    try seedCursor(allocator, seed, fx.correlation_y, 2);
    const y3 = try seedOldCompletion(allocator, seed, fx.correlation_y, 3);
    defer allocator.free(y3);
    const y5 = try seedOldCompletion(allocator, seed, fx.correlation_y, 5);
    defer allocator.free(y5);

    const sweep_conn = try pool.acquire();
    defer pool.release(sweep_conn);
    const swept = try sweeper.sweepStalledCorrelations(allocator, sweep_conn, 5);
    defer {
        for (swept) |s| s.deinit(allocator);
        allocator.free(swept);
    }

    // Nothing swept; Y's rows remain PENDING.
    try std.testing.expectEqual(@as(usize, 0), swept.len);
    const pending_y = try connCount(allocator, seed, "SELECT count(*) FROM plat_effect_completion WHERE correlation_id = $1 AND status = 'PENDING'", &.{fx.correlation_y});
    try std.testing.expectEqual(@as(u64, 2), pending_y);
}

// ---------------------------------------------------------------------------
// AC6 — ON CONFLICT DO NOTHING absorbs a re-insert
// ---------------------------------------------------------------------------

test "TC-ORD-03-AC6-on-conflict-do-nothing: a re-inserted completion is absorbed" {
    // covers: ORD-03
    const allocator = std.testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const fx = try Fixtures.init(allocator);
    defer fx.deinit(allocator);
    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanup(allocator, conn, fx);

    try cursor.recordCompletion(allocator, conn, fx.correlation_x, 5);
    // Second insert of the same (correlation_id, sequence_no) must be absorbed
    // (ON CONFLICT DO NOTHING) with no error and no duplicate row.
    try cursor.recordCompletion(allocator, conn, fx.correlation_x, 5);

    const count = try connCount(allocator, conn, "SELECT count(*) FROM plat_effect_completion WHERE correlation_id = $1 AND sequence_no = 5", &.{fx.correlation_x});
    try std.testing.expectEqual(@as(u64, 1), count);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn connCount(allocator: std.mem.Allocator, conn: *bpm.pool.Conn, sql: []const u8, params: []const []const u8) !u64 {
    var result = try conn.query(allocator, sql, params);
    defer result.deinit();
    if (result.rows.len == 0 or result.rows[0].len == 0 or result.rows[0][0] == null)
        return error.PersistenceFailed;
    return std.fmt.parseInt(u64, result.rows[0][0].?, 10) catch error.PersistenceFailed;
}
