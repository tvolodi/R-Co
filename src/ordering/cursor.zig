//! Ordering subsystem — pure DB operations on plat_effect_completion /
//! plat_correlation_cursor. Mirrors effects/queue.zig's split (queue.zig =
//! pure DB operations, worker.zig = polling loop + orchestration).
//!
//! Design artefact: src/design/ord-01-02-04-correlated-effect-reentry.md
//!
//! `claimOneCompletion` implements ORD-01's claim query; `tryExecuteGuard`
//! implements ORD-02's advisory-lock guard on the SAME connection/
//! transaction. Both MUST be called on a connection already inside an open
//! transaction (conn.begin() already called by the caller) — the row lock
//! and the advisory lock are only meaningful for that transaction's
//! lifetime, exactly like effects/queue.zig::fetchDueRows's FOR UPDATE SKIP
//! LOCKED contract.
//!
//! Security: all values are bound as $N parameters — no SQL string
//! interpolation.
const std = @import("std");
const mod = @import("ordering_mod");

/// Claims the single oldest-outstanding PENDING completion row via
/// `FOR UPDATE SKIP LOCKED`, ordered by (correlation_id, sequence_no) per
/// ORD-01's exact claim query shape. MUST be called inside an already-open
/// transaction on `conn` — the row lock is scoped to that transaction and
/// released at COMMIT/ROLLBACK.
///
/// Returns null (not an error) when no PENDING row is available, mirroring
/// ORD-01 AC2's "receives no row ... without raising an error."
pub fn claimOneCompletion(
    allocator: std.mem.Allocator,
    conn: anytype,
) mod.OrderingError!?mod.ClaimedCompletion {
    var result = conn.query(
        allocator,
        \\SELECT completion_id::text, correlation_id, sequence_no::text
        \\FROM plat_effect_completion
        \\WHERE status = 'PENDING'
        \\ORDER BY correlation_id, sequence_no
        \\FOR UPDATE SKIP LOCKED
        \\LIMIT 1
    ,
        &.{},
    ) catch return error.PersistenceFailed;
    defer result.deinit();

    if (result.rows.len == 0) return null;
    const row = result.rows[0];
    if (row.len < 3) return error.PersistenceFailed;

    const completion_id_raw = row[0] orelse return error.PersistenceFailed;
    const correlation_id_raw = row[1] orelse return error.PersistenceFailed;
    const sequence_no_raw = row[2] orelse return error.PersistenceFailed;

    const completion_id = allocator.dupe(u8, completion_id_raw) catch return error.OutOfMemory;
    errdefer allocator.free(completion_id);
    const correlation_id = allocator.dupe(u8, correlation_id_raw) catch return error.OutOfMemory;
    errdefer allocator.free(correlation_id);
    const sequence_no = std.fmt.parseInt(i64, sequence_no_raw, 10) catch return error.PersistenceFailed;

    return mod.ClaimedCompletion{
        .completion_id = completion_id,
        .correlation_id = correlation_id,
        .sequence_no = sequence_no,
    };
}

/// Evaluates ORD-02's per-correlation execute guard:
/// `SELECT pg_try_advisory_xact_lock(hashtext(correlation_id)::bigint)`.
/// MUST be called on the SAME connection/transaction `claimOneCompletion`
/// used — the process doc requires the row lock and the advisory lock to
/// span the same transaction window. The lock is transaction-scoped and
/// MUST NOT be released by an explicit unlock call; it releases at
/// COMMIT/ROLLBACK per ORD-02 AC2/AC5 and the process doc's "Try, never
/// wait" business rule.
pub fn tryExecuteGuard(
    allocator: std.mem.Allocator,
    conn: anytype,
    correlation_id: []const u8,
) mod.OrderingError!mod.ExecuteGuardOutcome {
    var result = conn.query(
        allocator,
        "SELECT pg_try_advisory_xact_lock(hashtext($1)::bigint)",
        &.{correlation_id},
    ) catch return error.PersistenceFailed;
    defer result.deinit();

    if (result.rows.len == 0 or result.rows[0].len == 0) return error.PersistenceFailed;
    const raw = result.rows[0][0] orelse return error.PersistenceFailed;
    if (std.mem.eql(u8, raw, "t") or std.mem.eql(u8, raw, "true")) return .acquired;
    if (std.mem.eql(u8, raw, "f") or std.mem.eql(u8, raw, "false")) return .busy;
    return error.PersistenceFailed;
}

/// ORD-03 extension point (not implemented in this batch): reads
/// applied_seq for `correlation_id` from plat_correlation_cursor, inserting a
/// fresh row at applied_seq=0 if absent (the process doc's MissingCursorRow
/// recovery path). Declared here only so ORD-01/02's design does not paint
/// ORD-03 into a corner on table shape — it is NOT called by this batch's
/// consumer loop (see consumer.zig::stubAlwaysDeferred). ORD-03's own design
/// (a later batch) owns the implementation and the order-guard/apply/
/// cursor-advance logic in full.
pub fn readOrInitCursor(
    allocator: std.mem.Allocator,
    conn: anytype,
    correlation_id: []const u8,
) mod.OrderingError!i64 {
    var result = conn.query(
        allocator,
        "SELECT applied_seq::text FROM plat_correlation_cursor WHERE correlation_id = $1",
        &.{correlation_id},
    ) catch return error.PersistenceFailed;
    defer result.deinit();

    if (result.rows.len > 0 and result.rows[0].len > 0) {
        const raw = result.rows[0][0] orelse return error.PersistenceFailed;
        return std.fmt.parseInt(i64, raw, 10) catch error.PersistenceFailed;
    }

    // MissingCursorRow: insert a fresh row at applied_seq=0 inside the same
    // transaction; a concurrent inserter is absorbed by ON CONFLICT DO
    // NOTHING (the PK is correlation_id) rather than racing to a duplicate
    // key error.
    conn.exec(
        "INSERT INTO plat_correlation_cursor (correlation_id, applied_seq) VALUES ($1, 0) ON CONFLICT (correlation_id) DO NOTHING",
        &.{correlation_id},
    ) catch return error.PersistenceFailed;

    var reread = conn.query(
        allocator,
        "SELECT applied_seq::text FROM plat_correlation_cursor WHERE correlation_id = $1",
        &.{correlation_id},
    ) catch return error.PersistenceFailed;
    defer reread.deinit();
    if (reread.rows.len == 0 or reread.rows[0].len == 0) return error.PersistenceFailed;
    const raw = reread.rows[0][0] orelse return error.PersistenceFailed;
    return std.fmt.parseInt(i64, raw, 10) catch error.PersistenceFailed;
}
