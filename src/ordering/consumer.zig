//! Ordering subsystem — polling loop + orchestration. Mirrors
//! effects/worker.zig's shape (queue.zig = pure DB ops, worker.zig = polling
//! loop + orchestration).
//!
//! Design artefact: src/design/ord-01-02-04-correlated-effect-reentry.md
//!
//! Connection acquisition (DB-02, ORD-01 "one pooled connection per claim
//! transaction"): each consumer's `runOneCycle` acquires ONE connection for
//! the whole cycle (claim + guard + apply + commit/rollback all share this
//! connection — unlike EXP-301's fetch/process split — because ORD-01/02/03's
//! row lock and advisory lock must span the SAME transaction by requirement,
//! not by convenience) and releases it in every path before returning. The
//! OUTER poll loop (`pollLoopStep`, one call per consumer per tick) holds a
//! connection ONLY for the duration of one `runOneCycle` call — never across
//! the poll-interval sleep. This matches effects/worker.zig's GH-654/ISS-0649
//! lesson (documented in that file's sweepOnce comment): never hold a pooled
//! connection idle across a sleep, since that starves the pool under a small
//! pool_size exactly the way that regression did.
const std = @import("std");
const mod = @import("ordering_mod");
const cursor = @import("ordering_cursor");

/// ORD-03's extension point: given a claimed row (with the execute guard
/// already held), apply it and report the outcome. This batch supplies ONLY
/// `stubAlwaysDeferred` below, which always treats every claim as "not yet —
/// ORD-03 not implemented," rolling back without error and without consuming
/// a retry, so that wiring this consumer loop before ORD-03 lands cannot
/// misapply anything. ORD-03's own batch replaces this function pointer with
/// the real order-guard + apply + cursor-advance logic; no signature change
/// is expected.
pub const ApplyFn = *const fn (
    allocator: std.mem.Allocator,
    conn: anytype,
    claim: mod.ClaimedCompletion,
) mod.OrderingError!ApplyOutcome;

pub const ApplyOutcome = enum {
    /// ORD-03: cursor advanced, status -> APPLIED, COMMIT.
    applied,
    /// ORD-03: not next in sequence (or, this batch's stub: always) —
    /// ROLLBACK, no error, no retry increment.
    deferred,
    /// ORD-03: engine error during apply — ROLLBACK, retry policy governs
    /// next attempt.
    apply_failed,
};

pub const CycleOutcome = enum { no_row, guard_lost, cycle_complete };

/// This batch's applyFn — always returns `.deferred`, never touches
/// plat_correlation_cursor, and never emits any event: a true no-op
/// placeholder. Running this batch's consumer loop against seeded PENDING
/// rows must leave status='PENDING' and plat_correlation_cursor.applied_seq
/// unchanged for every row, proving the stub cannot misapply anything ahead
/// of ORD-03.
pub fn stubAlwaysDeferred(
    allocator: std.mem.Allocator,
    conn: anytype,
    claim: mod.ClaimedCompletion,
) mod.OrderingError!ApplyOutcome {
    _ = allocator;
    _ = conn;
    _ = claim;
    return .deferred;
}

/// Generic over the connection type so this module has no compile-time
/// dependency on the concrete `pg`/pool vendor types — matches
/// cursor.zig's own `conn: anytype` shape. Callers pass a `*db.Pool`
/// (`src/db/pool.zig`).
pub fn ConsumerRunConfig(comptime Conn: type) type {
    return struct {
        config: mod.OrderingConfig,
        applyFn: *const fn (
            allocator: std.mem.Allocator,
            conn: *Conn,
            claim: mod.ClaimedCompletion,
        ) mod.OrderingError!ApplyOutcome,
    };
}

/// One full claim-guard-apply cycle for one consumer. Returns whether a row
/// was found at all so the caller's poll loop knows when to sleep (ORD-01
/// AC2: sleep `poll_interval_ms` only when no row was claimed).
///
/// `Pool` is generic (not hardcoded to `src/db/pool.zig::Pool`) so this
/// module stays testable/reusable without a hard compile-time dependency on
/// one pool implementation — callers pass `*db.Pool` in production and in
/// integration tests alike; `Pool.acquire()`/`.release()` and the returned
/// connection's `.begin()`/`.commit()`/`.rollback()` are the only contract
/// this function relies on, mirroring cursor.zig's `conn: anytype` pattern.
pub fn runOneCycle(
    allocator: std.mem.Allocator,
    pool: anytype,
    run_config: anytype,
    metrics: *@import("ordering_observability").ObservabilityCounters,
) mod.OrderingError!CycleOutcome {
    const conn = pool.acquire() catch return error.PoolExhausted;
    defer pool.release(conn);

    conn.begin() catch return error.PersistenceFailed;

    const claim = cursor.claimOneCompletion(allocator, conn) catch |err| {
        conn.rollback() catch {};
        return err;
    } orelse {
        conn.rollback() catch {};
        return .no_row;
    };
    defer claim.deinit(allocator);

    const guard_outcome = cursor.tryExecuteGuard(allocator, conn, claim.correlation_id) catch |err| {
        conn.rollback() catch {};
        return err;
    };
    metrics.recordGuardAttempt(guard_outcome);

    if (guard_outcome == .busy) {
        conn.rollback() catch {};
        return .guard_lost;
    }

    const apply_outcome = run_config.applyFn(allocator, conn, claim) catch |err| {
        conn.rollback() catch {};
        return err;
    };

    switch (apply_outcome) {
        .deferred => {
            // Row stays PENDING, no retry increment — ORD-01/ORD-02's
            // no-error contract, and this batch's stub always takes this
            // branch.
            conn.rollback() catch {};
            return .cycle_complete;
        },
        .applied => {
            // ORD-03's concern; this batch's stub never returns this.
            conn.commit() catch return error.PersistenceFailed;
            return .cycle_complete;
        },
        .apply_failed => {
            // ORD-03's concern; this batch's stub never returns this.
            conn.rollback() catch {};
            return .cycle_complete;
        },
    }
}

/// The per-tick driver: one call per consumer. Never returns an error to the
/// caller; it logs and continues, matching effects/worker.zig's sweepOnce
/// philosophy that one consumer's failure must not stop the poll loop.
///
/// Holds a pooled connection ONLY for the duration of the inner
/// `runOneCycle` call (see this file's header comment) — the caller is
/// responsible for sleeping `config.poll_interval_ms` between calls to this
/// function when it returns `.no_row`, and MUST NOT hold any connection open
/// across that sleep (GH-654/ISS-0649).
pub fn pollLoopStep(
    allocator: std.mem.Allocator,
    pool: anytype,
    run_config: anytype,
    metrics: *@import("ordering_observability").ObservabilityCounters,
) void {
    _ = runOneCycle(allocator, pool, run_config, metrics) catch |err| {
        logConsumerError("ordering.consumer.cycle_failed", @errorName(err));
    };
}

/// std.log rather than src/obs/logger.zig's structured JSON logger: this
/// module is deliberately kept free of a compile-time dependency on
/// src/api/trace_context.zig (which src/obs/logger.zig reaches by relative
/// import, escaping src/ordering/'s own module root when this file is built
/// as its own named module — see build.zig's ordering_consumer_mod). This
/// matches the module's existing `conn: anytype` / `pool: anytype` pattern of
/// minimizing compile-time coupling to the rest of the tree; production
/// callers that want structured JSON logs for these failures can wrap
/// pollLoopStep with their own logging at the call site.
fn logConsumerError(component: []const u8, message: []const u8) void {
    std.log.err("{s}: {s}", .{ component, message });
}
