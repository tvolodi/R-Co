//! Ordering subsystem shared types and constants — ORD-01/02/04
//!
//! Design artefact: src/design/ord-01-02-04-correlated-effect-reentry.md
//! Authoritative process: docs/processes/system/effect-reentry-ordering.md
//! (sys-effect-reentry-ordering, PW-07)
//!
//! Implements the BPM Consumer side of the correlated effect re-entry
//! process: a fixed pool of `consumer_count` independent polling loops that
//! each (a) claim one PENDING completion row via FOR UPDATE SKIP LOCKED
//! (ORD-01, src/ordering/cursor.zig::claimOneCompletion), (b) guard against a
//! sibling consumer already being inside the same correlation via a
//! transaction-scoped advisory lock (ORD-02,
//! src/ordering/cursor.zig::tryExecuteGuard), and (c) — once ORD-03's order
//! guard and apply step land in a later batch — advance the correlation's
//! cursor and commit. This batch's own consumer loop
//! (src/ordering/consumer.zig) never applies anything: its `applyFn` is
//! `stubAlwaysDeferred`, an explicit extension point for ORD-03.
//!
//! This batch's scope: the claim guard (ORD-01), the execute guard (ORD-02),
//! and the parallelism/observability surface (ORD-04) — process doc steps
//! 1-3 and 8, 10, 11, plus the two new tables (plat_effect_completion,
//! plat_correlation_cursor). Steps 4-7 (order guard, apply, cursor advance,
//! commit) and step 9 (gap sweeper dead-lettering) belong to ORD-03, not this
//! batch.
const std = @import("std");

/// Mirrors plat_effect_completion.status's three-value CHECK constraint.
pub const CompletionStatus = enum {
    pending,
    applied,
    dead,

    pub fn toWire(self: CompletionStatus) []const u8 {
        return switch (self) {
            .pending => "PENDING",
            .applied => "APPLIED",
            .dead => "DEAD",
        };
    }

    pub fn fromWire(s: []const u8) ?CompletionStatus {
        if (std.mem.eql(u8, s, "PENDING")) return .pending;
        if (std.mem.eql(u8, s, "APPLIED")) return .applied;
        if (std.mem.eql(u8, s, "DEAD")) return .dead;
        return null;
    }
};

/// Every ORD-01/02/04 tunable, per the process doc's Inputs/SLA tables.
pub const OrderingConfig = struct {
    /// ORD-04's default; floor 2 (ORD-04 AC3). Live/mutable at runtime once
    /// contention reduces it — see `consumer_count_floor` below and the
    /// design doc's open question #4 (BACKEND-DEV owns the mutable storage;
    /// this struct's field is the static starting value).
    consumer_count: u32 = 8,
    /// ORD-01 AC2 / SLA table "Claim poll interval".
    poll_interval_ms: u64 = 200,
    /// Owned here for config plumbing; consumed by ORD-03's sweeper.
    gap_timeout_seconds: u32 = 300,
    /// ORD-04 AC2.
    lag_threshold: u32 = 100,
    /// ORD-04 AC3.
    contention_threshold_pct: u8 = 50,
    contention_window_seconds: u32 = 60,
    /// ORD-04 AC3 "floor of 2".
    consumer_count_floor: u32 = 2,
    /// ORD-04 AC3 "reduced by 2".
    consumer_count_step_down: u32 = 2,
};

/// Decoded claim row shape, mirroring effects/queue.zig's OutboxRow
/// (individually-freed fields, explicit deinit()).
pub const ClaimedCompletion = struct {
    completion_id: []u8,
    correlation_id: []u8,
    sequence_no: i64,

    pub fn deinit(self: ClaimedCompletion, allocator: std.mem.Allocator) void {
        allocator.free(self.completion_id);
        allocator.free(self.correlation_id);
    }
};

/// Deliberately narrow, matching EffectQueueError's precedent — every OTHER
/// outcome the process doc names (ClaimContention, CorrelationBusy,
/// OutOfOrderCompletion, CursorRaceLost, ConsumerCrash) is NOT a Zig error in
/// this design, because the process doc itself states each is a normal,
/// expected control-flow outcome. Representing them as enum return values
/// (?ClaimedCompletion, ExecuteGuardOutcome, ApplyOutcome) rather than
/// error{} set members keeps that distinction visible in the type system.
pub const OrderingError = error{
    /// pool.acquire() failed.
    PoolExhausted,
    /// Any query/exec failure not otherwise classified.
    PersistenceFailed,
    OutOfMemory,
};

/// ORD-02's execute-guard outcome. Not a Zig error — losing the guard is
/// normal control flow (process doc step 3: "another consumer is inside this
/// correlation," no error), matching ORD-02 AC1's wording exactly.
pub const ExecuteGuardOutcome = enum { acquired, busy };
