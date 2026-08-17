//! ORD-03 — Sequence order guard gap sweeping (step 9 of
//! docs/processes/system/effect-reentry-ordering.md, PW-07).
//!
//! Design artefact: src/design/ord-03-sequence-order-guard-gap-sweeping.md
//!
//! On the scheduler's 60 s cadence, `sweepStalledCorrelations` finds
//! correlations whose successor has been PENDING longer than
//! `gap_timeout_seconds` (default 300) while its predecessor (applied_seq + 1)
//! is absent — i.e. the correlation's lowest PENDING sequence_no is ahead of
//! the cursor and that row is old — then, per correlation, in ONE transaction,
//! moves every PENDING row of that correlation to `status = 'DEAD'` and
//! returns the swept set for DLQ routing (OBS-05) as one unit (ORD-03 AC5).
//!
//! Connection discipline: the caller acquires one connection for the 60 s pass
//! and releases it BEFORE the DLQ insert (which runs on a fresh connection), so
//! the sweep's connection is never held across the DLQ write. Each correlation
//! transition owns its own transaction on the passed conn.
//!
//! Security: every value is bound as a $N parameter; no SQL interpolation.
const std = @import("std");
const mod = @import("ordering_mod");

/// One correlation the gap sweeper dead-lettered as a unit.
pub const SweptCorrelation = struct {
    correlation_id: []u8,
    /// Every PENDING sequence_no of the correlation, in ascending order.
    unapplied_sequence_nos: []i64,
    pending_row_count: u64,

    pub fn deinit(self: SweptCorrelation, allocator: std.mem.Allocator) void {
        allocator.free(self.correlation_id);
        allocator.free(self.unapplied_sequence_nos);
    }
};

/// Find correlations whose successor has been PENDING longer than
/// `gap_timeout_seconds` while its predecessor (applied_seq + 1) is absent,
/// then — per correlation, in ONE transaction — set every PENDING row to
/// 'DEAD' and return the correlation for DLQ routing (ORD-03 AC5).
///
/// `conn` must be a freshly-acquired connection (not inside a transaction);
/// the function opens and commits one transaction per swept correlation.
pub fn sweepStalledCorrelations(
    allocator: std.mem.Allocator,
    conn: anytype,
    gap_timeout_seconds: u32,
) mod.OrderingError![]SweptCorrelation {
    const timeout_text = std.fmt.allocPrint(allocator, "{d}", .{gap_timeout_seconds}) catch return error.OutOfMemory;
    defer allocator.free(timeout_text);

    // Stalled correlations: lowest PENDING sequence_no strictly AHEAD of the
    // next expected sequence (applied_seq + 1) — i.e. the predecessor is
    // genuinely absent — AND that row older than the gap timeout. A completion
    // at exactly applied_seq + 1 is the NEXT expected one (slow-but-present)
    // and must NOT be swept (ORD-03 AC5). SELECT DISTINCT ON picks the
    // lowest-sequence PENDING row per correlation.
    const stalled = conn.query(
        allocator,
        \\SELECT p.correlation_id::text, p.lowest_seq::text
        \\FROM (
        \\  SELECT DISTINCT ON (correlation_id)
        \\         correlation_id, sequence_no AS lowest_seq, received_at
        \\  FROM plat_effect_completion
        \\  WHERE status = 'PENDING'
        \\  ORDER BY correlation_id, sequence_no
        \\) p
        \\JOIN plat_correlation_cursor c ON c.correlation_id = p.correlation_id
        \\WHERE p.lowest_seq > c.applied_seq + 1
        \\  AND p.received_at <= now() - make_interval(secs => $1)
    ,
        &.{timeout_text},
    ) catch return error.PersistenceFailed;
    defer {
        var r = stalled;
        r.deinit();
    }

    var swept: std.ArrayList(SweptCorrelation) = .empty;
    errdefer {
        for (swept.items) |s| s.deinit(allocator);
        swept.deinit(allocator);
    }

    for (stalled.rows) |row| {
        if (row.len < 2 or row[0] == null or row[1] == null) return error.PersistenceFailed;
        const correlation_id = allocator.dupe(u8, row[0].?) catch return error.OutOfMemory;
        errdefer allocator.free(correlation_id);

        // Collect every unapplied (PENDING) sequence_no of the correlation so
        // the DLQ entry can name them without querying the completion table
        // (ORD-03 AC5 / ORD-04 AC4).
        const seqs = conn.query(
            allocator,
            \\SELECT sequence_no::text
            \\FROM plat_effect_completion
            \\WHERE correlation_id = $1 AND status = 'PENDING'
            \\ORDER BY sequence_no
        ,
            &.{row[0].?},
        ) catch return error.PersistenceFailed;
        defer {
            var r = seqs;
            r.deinit();
        }

        var seq_list: std.ArrayList(i64) = .empty;
        errdefer seq_list.deinit(allocator);
        for (seqs.rows) |seq_row| {
            if (seq_row.len == 0 or seq_row[0] == null) return error.PersistenceFailed;
            const seq = std.fmt.parseInt(i64, seq_row[0].?, 10) catch return error.PersistenceFailed;
            seq_list.append(allocator, seq) catch return error.OutOfMemory;
        }
        const seq_owned = seq_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
        errdefer allocator.free(seq_owned);
        const pending_row_count: u64 = @intCast(seq_owned.len);

        // One transaction per correlation: PENDING -> DEAD for ALL rows.
        conn.begin() catch return error.PersistenceFailed;
        errdefer conn.rollback() catch {};
        conn.exec(
            "UPDATE plat_effect_completion SET status = 'DEAD' WHERE correlation_id = $1 AND status = 'PENDING'",
            &.{row[0].?},
        ) catch return error.PersistenceFailed;
        conn.commit() catch return error.PersistenceFailed;

        const item = SweptCorrelation{
            .correlation_id = correlation_id,
            .unapplied_sequence_nos = seq_owned,
            .pending_row_count = pending_row_count,
        };
        swept.append(allocator, item) catch |err| {
            item.deinit(allocator);
            return err;
        };
    }

    return swept.toOwnedSlice(allocator) catch return error.OutOfMemory;
}
