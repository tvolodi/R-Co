//! Ordering subsystem — ORD-04's lag/contention observability surface.
//!
//! Design artefact: src/design/ord-01-02-04-correlated-effect-reentry.md
//!
//! `ObservabilityCounters` holds in-process counters a consumer's poll loop
//! updates every cycle, mirroring the shape of src/obs/metrics.zig's
//! existing in-process Prometheus-counter pattern. `contentionRatioLastWindow`
//! computes ORD-04 AC3's rolling percentage over `contention_window_seconds`
//! using a simple fixed 60s bucket (the design doc's open question #2 leaves
//! the windowing implementation to BACKEND-DEV; a fixed bucket satisfies
//! ORD-04 AC3's literal wording — "more than 50 per cent of claim attempts in
//! one minute" — without introducing a second sliding-window implementation
//! alongside src/api/middleware/ratelimit.zig's HTTP-specific one).
//!
//! `CorrelationLagRow` and `computeCorrelationLag` implement ORD-04 AC1/AC2:
//! per-correlation lag (max(sequence_no) - applied_seq) and the age of the
//! oldest PENDING row, read directly off plat_effect_completion joined
//! against plat_correlation_cursor. Wiring into the scheduler's existing 60s
//! cadence (process doc step 10/11) is a BACKEND-DEV implementation detail
//! left for the caller (this batch does not spawn its own timer thread).
const std = @import("std");
const mod = @import("ordering_mod");

/// In-process counters a consumer's poll loop updates every cycle. Uses
/// std.atomic.Value like effects/mod.zig's precedent-free counters would,
/// matching the ObservabilityCounters shape the design doc specifies.
pub const ObservabilityCounters = struct {
    execute_guard_attempts: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    execute_guard_busy: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Fixed 60s bucket for the contention ratio: each field is reset by the
    /// caller (typically the scheduler's periodic sweep) once per window via
    /// `resetWindow`. Not itself time-aware — the caller decides when a
    /// window has elapsed, matching how src/scheduler/scheduler.zig already
    /// drives its own periodic cadence without embedding a clock in the
    /// counter struct itself.
    window_attempts: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    window_busy: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn recordGuardAttempt(self: *ObservabilityCounters, outcome: mod.ExecuteGuardOutcome) void {
        _ = self.execute_guard_attempts.fetchAdd(1, .monotonic);
        _ = self.window_attempts.fetchAdd(1, .monotonic);
        if (outcome == .busy) {
            _ = self.execute_guard_busy.fetchAdd(1, .monotonic);
            _ = self.window_busy.fetchAdd(1, .monotonic);
        }
    }

    /// ORD-04 AC3's "more than 50 per cent of claim attempts in one minute."
    /// Returns 0.0 when the window has recorded zero attempts (no
    /// contention observed, not undefined).
    pub fn contentionRatioLastWindow(self: *ObservabilityCounters) f64 {
        const attempts = self.window_attempts.load(.monotonic);
        if (attempts == 0) return 0.0;
        const busy = self.window_busy.load(.monotonic);
        return @as(f64, @floatFromInt(busy)) / @as(f64, @floatFromInt(attempts));
    }

    /// Reset the rolling window's counters. Called by the periodic sweep
    /// (the scheduler's existing cadence) once per `contention_window_seconds`.
    pub fn resetWindow(self: *ObservabilityCounters) void {
        self.window_attempts.store(0, .monotonic);
        self.window_busy.store(0, .monotonic);
    }
};

pub const CorrelationLagRow = struct {
    correlation_id: []u8,
    /// max(sequence_no) - applied_seq, ORD-04 AC2.
    lag: i64,
    oldest_pending_age_seconds: i64,

    pub fn deinit(self: CorrelationLagRow, allocator: std.mem.Allocator) void {
        allocator.free(self.correlation_id);
    }
};

/// Returns only rows exceeding `lag_threshold` OR whose oldest pending row's
/// age exceeds `gap_timeout_seconds` — ORD-04 AC2's two triggers, both
/// routed through one function since both read the same two tables in one
/// query.
pub fn computeCorrelationLag(
    allocator: std.mem.Allocator,
    conn: anytype,
    lag_threshold: u32,
    gap_timeout_seconds: u32,
) mod.OrderingError![]CorrelationLagRow {
    const threshold_str = std.fmt.allocPrint(allocator, "{d}", .{lag_threshold}) catch return error.OutOfMemory;
    defer allocator.free(threshold_str);
    const gap_str = std.fmt.allocPrint(allocator, "{d}", .{gap_timeout_seconds}) catch return error.OutOfMemory;
    defer allocator.free(gap_str);

    var result = conn.query(
        allocator,
        \\SELECT
        \\  pec.correlation_id,
        \\  (MAX(pec.sequence_no) - pcc.applied_seq)::text AS lag,
        \\  EXTRACT(EPOCH FROM (NOW() - MIN(pec.received_at) FILTER (WHERE pec.status = 'PENDING')))::bigint::text AS oldest_pending_age_seconds
        \\FROM plat_effect_completion pec
        \\JOIN plat_correlation_cursor pcc ON pcc.correlation_id = pec.correlation_id
        \\GROUP BY pec.correlation_id, pcc.applied_seq
        \\HAVING (MAX(pec.sequence_no) - pcc.applied_seq) > $1::bigint
        \\    OR COALESCE(EXTRACT(EPOCH FROM (NOW() - MIN(pec.received_at) FILTER (WHERE pec.status = 'PENDING'))), 0) > $2::bigint
    ,
        &.{ threshold_str, gap_str },
    ) catch return error.PersistenceFailed;
    defer result.deinit();

    var out = std.ArrayList(CorrelationLagRow).empty;
    errdefer {
        for (out.items) |item| item.deinit(allocator);
        out.deinit(allocator);
    }

    for (result.rows) |row| {
        if (row.len < 3) continue;
        const correlation_id_raw = row[0] orelse continue;
        const lag_raw = row[1] orelse "0";
        const age_raw = row[2] orelse "0";

        const correlation_id = allocator.dupe(u8, correlation_id_raw) catch return error.OutOfMemory;
        errdefer allocator.free(correlation_id);
        const lag = std.fmt.parseInt(i64, lag_raw, 10) catch return error.PersistenceFailed;
        const age = std.fmt.parseInt(i64, age_raw, 10) catch return error.PersistenceFailed;

        out.append(allocator, CorrelationLagRow{
            .correlation_id = correlation_id,
            .lag = lag,
            .oldest_pending_age_seconds = age,
        }) catch {
            allocator.free(correlation_id);
            return error.OutOfMemory;
        };
    }

    return out.toOwnedSlice(allocator) catch error.OutOfMemory;
}

test "ObservabilityCounters: contentionRatioLastWindow is 0.0 with no recorded attempts" {
    var counters = ObservabilityCounters{};
    try std.testing.expectEqual(@as(f64, 0.0), counters.contentionRatioLastWindow());
}

test "ObservabilityCounters: contentionRatioLastWindow computes busy/attempts ratio" {
    var counters = ObservabilityCounters{};
    counters.recordGuardAttempt(.acquired);
    counters.recordGuardAttempt(.busy);
    counters.recordGuardAttempt(.busy);
    counters.recordGuardAttempt(.busy);
    // 3 busy out of 4 attempts = 0.75, exceeding ORD-04 AC3's 50% threshold.
    try std.testing.expectEqual(@as(f64, 0.75), counters.contentionRatioLastWindow());
    try std.testing.expectEqual(@as(u64, 4), counters.execute_guard_attempts.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 3), counters.execute_guard_busy.load(.monotonic));
}

test "ObservabilityCounters: resetWindow clears the rolling window but not lifetime totals" {
    var counters = ObservabilityCounters{};
    counters.recordGuardAttempt(.busy);
    counters.recordGuardAttempt(.busy);
    try std.testing.expectEqual(@as(f64, 1.0), counters.contentionRatioLastWindow());

    counters.resetWindow();
    try std.testing.expectEqual(@as(f64, 0.0), counters.contentionRatioLastWindow());
    // Lifetime totals (execute_guard_attempts/busy) are untouched by a window
    // reset — only the rolling-window fields are cleared.
    try std.testing.expectEqual(@as(u64, 2), counters.execute_guard_attempts.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), counters.execute_guard_busy.load(.monotonic));

    counters.recordGuardAttempt(.acquired);
    // New window: 0 busy out of 1 attempt.
    try std.testing.expectEqual(@as(f64, 0.0), counters.contentionRatioLastWindow());
}

test "ObservabilityCounters: exactly-50-percent contention is at threshold, not exceeding it" {
    var counters = ObservabilityCounters{};
    counters.recordGuardAttempt(.acquired);
    counters.recordGuardAttempt(.busy);
    // ORD-04 AC3 says "more than 50 per cent" — exactly 50% must not itself
    // read as exceeding the threshold; the caller compares
    // contentionRatioLastWindow() > 0.5, not >=.
    try std.testing.expectEqual(@as(f64, 0.5), counters.contentionRatioLastWindow());
}
