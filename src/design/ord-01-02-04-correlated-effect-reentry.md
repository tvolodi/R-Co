# Module: ord-01-02-04-correlated-effect-reentry

**Requirement IDs:** ORD-01 (claim guard), ORD-02 (execute guard), ORD-04 (cross-correlation
parallelism + lag/contention observability)
**Run ID:** WF02-batch-2-20260811 (Stage 16)
**Not in this batch (referenced, not implemented):** ORD-03 (order guard + cursor advance +
gap sweeper dead-lettering) — this design is written to be **compatible with** ORD-03's
process steps 4-6 and 9 exactly as specified in `docs/processes/system/effect-reentry-ordering.md`,
since ORD-01/02/04 share the same claim transaction and the same two new tables ORD-03 also
reads/writes. ORD-03's own design (a later batch) must not need to change any schema or
function signature this design introduces.
**Authoritative process source:** `docs/processes/system/effect-reentry-ordering.md`
(`sys-effect-reentry-ordering`, PW-07) — already fully specifies the 11-step flow, the three
guards, the two tables' columns, and every event name. This design translates that process
into Zig module boundaries, error taxonomy, and the two Type C migrations; it does not
re-derive the process from scratch.
**See:** OBS-05 (DLQ inspect/retry/discard API — the DLQ entry this design's dead-letter path
produces must be visible there), PAR-01 (referenced only for event-log context; no schema
overlap), DB-02 (pooled connection per claim transaction)

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C — yes, for the schema.** ORD-01/04 require two new tables
   (`plat_effect_completion`, `plat_correlation_cursor`) that do not exist anywhere in the
   codebase yet (confirmed: `grep -r "plat_effect_completion\|plat_correlation_cursor" src/
   migrations/` matches only DDL-05's naming-convention prose/tests, never a real table). Two
   Type C migration YAMLs are produced alongside this document:
   `templates/specs/ord-01-plat-effect-completion.migration.yaml` and
   `templates/specs/ord-04-plat-correlation-cursor.migration.yaml`.
2. **Type E — yes, for the consumer logic.** The claim loop, execute guard, and
   parallelism/observability logic is a genuinely novel polling+advisory-lock consumer with no
   CRUD template shape (lego-catalog.md's own worked example under "How design classification
   works" — "add config repository" — is exactly the kind of mixed decomposition this
   catalog anticipates: Type C migration + Type E logic, no Type A/B/D component). It also
   falls under lego-catalog.md's explicit "never templated" list: "Cross-module orchestration
   sagas" and, by the same reasoning the effects-worker precedent (`src/effects/worker.zig`,
   EXP-301) already established for the sibling polling-consumer pattern, this is Type E.

So this batch produces: **2 Type C migration YAMLs + 1 Type E design document** (this file).

## Existing pattern found and followed

Per the handoff's explicit instruction to search for a prior consumer/polling pattern before
inventing a new one: **`src/effects/worker.zig` + `src/effects/queue.zig` (EXP-301, the
effects outbox worker) is that pattern**, and this design follows its shape closely:

| Aspect | EXP-301 precedent | ORD-01/02/04 (this design) |
|---|---|---|
| Claim query shape | `SELECT ... FROM effects_outbox WHERE status='pending' AND next_attempt_at<=NOW() ORDER BY next_attempt_at ASC LIMIT $1 FOR UPDATE SKIP LOCKED` (`queue.fetchDueRows`) | `SELECT ... FROM plat_effect_completion WHERE status='PENDING' ORDER BY correlation_id, sequence_no FOR UPDATE SKIP LOCKED LIMIT 1` — same `FOR UPDATE SKIP LOCKED` idiom, same "claim inside the transaction that applies it" discipline |
| Connection-per-phase discipline | `sweepOnce` acquires a connection to fetch, releases it, THEN acquires per-row connections to process (GH-654/ISS-0649 fix: never hold the fetch connection while processing) | Followed directly: the claim SELECT and the entire apply transaction are the SAME connection/transaction (this is a **hard requirement** of ORD-01/02/04, not optional — the claim, execute guard, and apply must be one transaction so the row lock and the advisory lock cover the same window), but the OUTER poll loop must not hold a connection between claim attempts — see "Connection acquisition" below |
| Retry/backoff module split | `queue.zig` = pure DB operations (insert/mark/fetch), `worker.zig` = polling loop + orchestration, `mod.zig` = shared types/constants | Followed: `src/ordering/cursor.zig` = pure DB operations on the two new tables, `src/ordering/consumer.zig` = polling loop + guards + orchestration, `src/ordering/mod.zig` = shared types/constants |
| Row → struct decode with per-field cleanup | `queue.OutboxRow` with a `deinit()` that frees every field individually, matching the manual dupe/free pattern `pg.zig`'s `conn.query()` requires | Followed: `ClaimedCompletion` gets the same shape and `deinit()` |
| Error philosophy | Typed error sets (`EffectQueueError`, `EffectDeliveryError`), no `catch unreachable` on realistic DB failures | Followed: `OrderingError` (see Error taxonomy below) |

**One precedent explicitly NOT followed, and why:** the scheduler (`src/scheduler/scheduler.zig`)
went through ISS-301, which **removed** a per-timer `pg_try_advisory_xact_lock` call because it
was redundant with `FOR UPDATE SKIP LOCKED` on the same row. ORD-02's advisory lock is **not**
the same situation and must not be removed by analogy:

- ISS-301's removed lock and its `SKIP LOCKED` covered the exact same critical section — one
  timer row. `SKIP LOCKED` alone already guarantees no two workers claim the *same* timer row,
  which is all that lock was ever protecting; the advisory lock added nothing.
- ORD-02's `pg_try_advisory_xact_lock(hashtext(correlation_id)::bigint)` protects a *different*
  hazard: two consumers each holding a **different** `plat_effect_completion` row (different
  `sequence_no`) of the **same** `correlation_id`. `SKIP LOCKED` on the claim query cannot
  prevent this — SKIP LOCKED only ever excludes rows already locked by another transaction, and
  ORD-01 AC4 explicitly requires that two `PENDING` rows of the same correlation with different
  `sequence_no` CAN both be claimed concurrently by the claim guard alone ("both claims succeed
  because they are different rows; ordering is decided downstream by ORD-02 and ORD-03, not
  here"). The advisory lock is the ONLY mechanism serializing "am I the only consumer currently
  inside this correlation" — removing it would let two consumers race to apply sequence_no 5 and
  6 of the same correlation concurrently, breaking ORD-03's order guard's implicit assumption
  that only one consumer evaluates/advances one correlation's cursor at a time.
- The design doc for ISS-301 (`src/design/scheduler-concurrency-epic3.md`) frames the removed
  lock as protecting the *same row*, calling it "redundant with SKIP LOCKED" for exactly that
  reason — its own rationale section, if reapplied here, would correctly identify ORD-02's lock
  as NOT redundant, since it spans multiple rows.

This distinction is called out explicitly so CODE-DESIGN-VALIDATOR (and any future reader who
knows the ISS-301 precedent) does not flag ORD-02's advisory lock as a repeat of a since-removed
anti-pattern — it solves a different problem than the one ISS-301 removed.

## Module purpose

Implements the BPM Consumer side of the correlated effect re-entry process
(`docs/processes/system/effect-reentry-ordering.md`, PW-07): a fixed pool of `consumer_count`
(default 8) independent polling loops that each (a) claim one `PENDING` completion row via
`FOR UPDATE SKIP LOCKED` (ORD-01), (b) guard against a sibling consumer already being inside the
same correlation via a transaction-scoped advisory lock (ORD-02), and (c) — once ORD-03's order
guard and apply step land in a later batch — advance the correlation's cursor and commit.
Distinct correlations are applied fully in parallel; this design additionally exposes the
per-correlation lag, oldest-pending-row age, and execute-guard rejection rate the scheduler's
gap sweeper (ORD-03, not this batch) and its own escalation logic (ORD-04) consume.

**This batch's exact scope:** the claim guard (ORD-01), the execute guard (ORD-02), and the
parallelism/observability surface (ORD-04) — steps 1-3 and 8, 10, 11 of the process table, plus
the two new tables. Step 4-7 (order guard, apply, cursor advance, commit) and step 9 (gap
sweeper dead-lettering) belong to ORD-03, a separate requirement not in this handoff; this
design defines an explicit extension point (`applyFn`, see below) for ORD-03 to fill in rather
than leaving a placeholder that silently no-ops.

## Public interface

### `src/ordering/mod.zig` — shared types and constants

`CompletionStatus` mirrors `plat_effect_completion.status`'s three-value CHECK constraint, and
`OrderingConfig` collects every tunable ORD-01/02/04 name (the process doc's Inputs/SLA tables).

```zig
pub const CompletionStatus = enum {
    pending,
    applied,
    dead,

    pub fn toWire(self: CompletionStatus) []const u8 { ... } // "PENDING"/"APPLIED"/"DEAD"
    pub fn fromWire(s: []const u8) ?CompletionStatus { ... } // mirrors mod.EffectKind.fromWire
};

pub const OrderingConfig = struct {
    consumer_count: u32 = 8,           // ORD-04's default; floor 2 (ORD-04 AC3)
    poll_interval_ms: u64 = 200,       // ORD-01 AC2 / SLA table "Claim poll interval"
    gap_timeout_seconds: u32 = 300,    // owned here for config plumbing; consumed by ORD-03's sweeper
    lag_threshold: u32 = 100,          // ORD-04 AC2
    contention_threshold_pct: u8 = 50, // ORD-04 AC3
    contention_window_seconds: u32 = 60,
    consumer_count_floor: u32 = 2,     // ORD-04 AC3 "floor of 2"
    consumer_count_step_down: u32 = 2, // ORD-04 AC3 "reduced by 2"
};
```

`ClaimedCompletion` is the decoded row shape, mirroring `effects/queue.zig`'s `OutboxRow`
(individually-freed fields, explicit `deinit()`). `OrderingError` is deliberately narrow — see
"Error taxonomy" below for why guard contention and out-of-order arrival are NOT represented as
Zig errors.

```zig
pub const ClaimedCompletion = struct {
    completion_id: []u8,
    correlation_id: []u8,
    sequence_no: i64,

    pub fn deinit(self: ClaimedCompletion, allocator: std.mem.Allocator) void {
        allocator.free(self.completion_id);
        allocator.free(self.correlation_id);
    }
};

pub const OrderingError = error{ PoolExhausted, PersistenceFailed, OutOfMemory };

/// ORD-02's execute-guard outcome. Not a Zig error — losing the guard is
/// normal control flow (process table step 3: "another consumer is inside
/// this correlation," no error), matching ORD-02 AC1's wording exactly.
pub const ExecuteGuardOutcome = enum { acquired, busy };
```

### `src/ordering/cursor.zig` — pure DB operations (mirrors `effects/queue.zig`)

`claimOneCompletion` implements ORD-01's claim query; `tryExecuteGuard` implements ORD-02's
advisory-lock guard on the SAME connection/transaction. Both MUST be called on a connection
already inside an open transaction (`conn.begin()` already called by the caller) — the row lock
and the advisory lock are only meaningful for that transaction's lifetime, exactly like
`queue.fetchDueRows`'s `FOR UPDATE SKIP LOCKED` contract. `claimOneCompletion` returns `null`
(not an error) when no `PENDING` row is available, mirroring ORD-01 AC2's "receives no row ...
without raising an error." `tryExecuteGuard`'s lock is transaction-scoped — the caller must NOT
call any unlock function; it releases at `COMMIT`/`ROLLBACK` per ORD-02 AC2/AC5 and the process
doc's "Try, never wait" business rule.

```zig
pub fn claimOneCompletion(
    allocator: std.mem.Allocator,
    conn: anytype,
) mod.OrderingError!?mod.ClaimedCompletion;

pub fn tryExecuteGuard(
    allocator: std.mem.Allocator,
    conn: anytype,
    correlation_id: []const u8,
) mod.OrderingError!mod.ExecuteGuardOutcome;
```

`readOrInitCursor` is an extension point for ORD-03 (not implemented in this batch): it reads
`applied_seq` for `correlation_id` from `plat_correlation_cursor`, inserting a fresh row at
`applied_seq=0` if absent (the process doc's `MissingCursorRow` recovery path, ORD-03's
concern). Declared here only so ORD-01/02's design does not paint ORD-03 into a corner on table
shape — it is NOT called by this batch's consumer loop. ORD-03's own design (a later batch)
owns the implementation and the order-guard/apply/cursor-advance logic in full.

```zig
pub fn readOrInitCursor(
    allocator: std.mem.Allocator,
    conn: anytype,
    correlation_id: []const u8,
) mod.OrderingError!i64;
```

### `src/ordering/consumer.zig` — polling loop + orchestration (mirrors `effects/worker.zig`)

`ConsumerRunConfig.applyFn` is ORD-03's extension point: given a claimed row (with the execute
guard already held), apply it and report the outcome. This batch supplies ONLY a stub
(`stubAlwaysDeferred`, below) that always treats every claim as "not yet — ORD-03 not
implemented," rolling back without error and without consuming a retry, so that wiring this
consumer loop into `main.zig` before ORD-03 lands cannot misapply anything. ORD-03's own batch
replaces this function pointer with the real order-guard + apply + cursor-advance logic; no
signature change is expected.

```zig
pub const ConsumerRunConfig = struct {
    config: mod.OrderingConfig,
    applyFn: *const fn (
        allocator: std.mem.Allocator,
        conn: anytype,
        claim: mod.ClaimedCompletion,
    ) mod.OrderingError!ApplyOutcome,
};

pub const ApplyOutcome = enum {
    applied,       // ORD-03: cursor advanced, status -> APPLIED, COMMIT
    deferred,      // ORD-03: not next in sequence (or, this batch's stub:
                   // always) — ROLLBACK, no error, no retry increment
    apply_failed,  // ORD-03: engine error during apply — ROLLBACK, retry
                   // policy governs next attempt
};
```

`runOneCycle` is one full claim-guard-apply cycle for one consumer, returning whether a row was
found at all so the caller's poll loop knows when to sleep (ORD-01 AC2: sleep 200ms only when no
row was claimed). `pollLoopStep` is the per-tick driver — it never returns an error to the
caller; it logs and continues, matching `effects/worker.zig`'s `sweepOnce` philosophy that one
consumer's failure must not stop the poll loop. This design does not introduce a new threading
primitive: it reuses whatever mechanism `src/scheduler/scheduler.zig` and
`src/effects/worker.zig` already use to run a polling function on an interval, invoked
`consumer_count` times (wiring detail left to BACKEND-DEV).

```zig
pub const CycleOutcome = enum { no_row, guard_lost, cycle_complete };

pub fn runOneCycle(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    run_config: ConsumerRunConfig,
    metrics: *ObservabilityCounters, // ORD-04, see below
) mod.OrderingError!CycleOutcome;

pub fn pollLoopStep(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    run_config: ConsumerRunConfig,
    metrics: *ObservabilityCounters,
) void;
```

`stubAlwaysDeferred` is this batch's `applyFn` — see `ConsumerRunConfig.applyFn` above. It
always returns `.deferred`, never touches `plat_correlation_cursor`, and never emits any event:
a true no-op placeholder.

```zig
pub fn stubAlwaysDeferred(
    allocator: std.mem.Allocator,
    conn: anytype,
    claim: mod.ClaimedCompletion,
) mod.OrderingError!ApplyOutcome;
```

### `src/ordering/observability.zig` — ORD-04's lag/contention surface

`ObservabilityCounters` holds in-process counters a consumer's poll loop updates every cycle,
mirroring the shape of `src/obs/metrics.zig`'s existing in-process Prometheus-counter pattern
(referenced, not re-derived) — this module adds ordering-specific counters to that existing
registry rather than building a parallel metrics system. `contentionRatioLastWindow` computes
ORD-04 AC3's rolling percentage over `contention_window_seconds`; the windowing mechanism
(fixed bucket vs. sliding) is left to BACKEND-DEV to match whatever `src/obs/metrics.zig`
already uses for other rate-based thresholds (e.g. `ratelimit.zig`'s existing sliding window)
rather than introducing a second windowing implementation.

```zig
pub const ObservabilityCounters = struct {
    execute_guard_attempts: std.atomic.Value(u64) = .init(0),
    execute_guard_busy: std.atomic.Value(u64) = .init(0),

    pub fn recordGuardAttempt(self: *ObservabilityCounters, outcome: mod.ExecuteGuardOutcome) void;
    pub fn contentionRatioLastWindow(self: *ObservabilityCounters) f64;
};
```

`CorrelationLagRow` and `computeCorrelationLag` implement ORD-04 AC1/AC2, computed by a periodic
sweep owned by the Scheduler role per the process doc's step 10/11 — the SAME background-timer
mechanism the scheduler already runs every 60s for its own gap sweep, not a new timer thread.
Declared here as the query shape; wiring into the scheduler's existing 60s cadence is a
BACKEND-DEV implementation detail, not a new module boundary. `computeCorrelationLag` returns
only rows exceeding `lag_threshold` OR whose oldest pending row's age exceeds
`gap_timeout_seconds` — ORD-04 AC2's two triggers, both routed through one function since both
read the same two tables in one query.

```zig
pub const CorrelationLagRow = struct {
    correlation_id: []u8,
    lag: i64,                    // max(sequence_no) - applied_seq, ORD-04 AC2
    oldest_pending_age_seconds: i64,

    pub fn deinit(self: CorrelationLagRow, allocator: std.mem.Allocator) void;
};

pub fn computeCorrelationLag(
    allocator: std.mem.Allocator,
    conn: anytype,
    lag_threshold: u32,
) mod.OrderingError![]CorrelationLagRow;
```

## Connection acquisition (DB-02, ORD-01 "one pooled connection per claim transaction")

Each consumer's `runOneCycle`:

1. `pool.acquire()` — ONE connection for the whole cycle (claim + guard + apply + commit/rollback
   all share this connection, unlike EXP-301's fetch/process split, because ORD-01/02/03's row
   lock and advisory lock must span the SAME transaction by requirement, not by convenience).
2. `conn.begin()`.
3. `cursor.claimOneCompletion(conn)` — if `null`, `conn.rollback()` (no-op transaction), release,
   return `.no_row`.
4. `cursor.tryExecuteGuard(conn, claim.correlation_id)` — if `.busy`, `conn.rollback()`, release,
   return `.guard_lost` (process doc step 3: "ROLLBACK, the row returns to PENDING, the consumer
   moves to the next correlation" — the CALLER's poll loop, not this function, decides what
   "moves to the next correlation" means operationally: it simply calls `runOneCycle` again
   immediately, no sleep, matching the SLA table's "no backoff" rule for guard rejection).
5. `run_config.applyFn(conn, claim)` — this batch's `stubAlwaysDeferred` or, later, ORD-03's
   real implementation.
6. Branch on `ApplyOutcome`:
   - `.deferred` -> `conn.rollback()`, release, return `.cycle_complete` (row stays `PENDING`,
     no retry increment — ORD-01/ORD-02's no-error contract, and this batch's stub always takes
     this branch).
   - `.applied` / `.apply_failed` -> ORD-03's concern; this batch's stub never returns these.
7. Release connection in all paths (`defer pool.release(conn)` at function entry, matching
   `effects/worker.zig`'s discipline).

The OUTER `pollLoopStep` (one call per consumer per tick) holds a connection **only** for the
duration of one `runOneCycle` call — never across the 200 ms poll-interval sleep. This matches
`effects/worker.zig`'s GH-654/ISS-0649 lesson (documented in that file's `sweepOnce` comment):
never hold a pooled connection idle across a sleep, since that starves the pool under a small
`pool_size` exactly the way that regression did.

## Data flow

```
consumer_count independent poll loops (this batch: N calls to pollLoopStep, one per consumer)
        |
        v  each tick, each consumer:
+-----------------------------------------------------------+
| runOneCycle                                                |
|  pool.acquire() -> conn.begin()                            |
|        |                                                    |
|        v                                                    |
|  claimOneCompletion(conn)   [ORD-01: FOR UPDATE SKIP LOCKED]|
|        |                                                    |
|    null? --------------------------> rollback, no_row       |
|        | row                                                |
|        v                                                    |
|  tryExecuteGuard(conn, correlation_id) [ORD-02: advisory]   |
|        |                                                    |
|    busy? --------------------------> rollback, guard_lost   |
|        | acquired                                           |
|        v                                                    |
|  applyFn(conn, claim)   [ORD-03 extension point; this batch |
|                          always stubAlwaysDeferred]          |
|        |                                                    |
|    deferred (always, this batch) --> rollback, cycle_complete|
|    applied/apply_failed (ORD-03) --> commit/rollback         |
+-----------------------------------------------------------+
        |
        v
  pool.release(conn)

Separately, on the scheduler's existing 60s cadence:
  computeCorrelationLag() -> ObservabilityCounters -> EXECUTION_CORRELATION_LAG /
                              EXECUTION_CORRELATION_CONTENTION events (ORD-04)
```

## Error taxonomy

```zig
pub const OrderingError = error{
    PoolExhausted,       // pool.acquire() failed
    PersistenceFailed,   // any query/exec failure not otherwise classified
    OutOfMemory,
};
```

Deliberately narrow, matching `EffectQueueError`'s precedent — every OTHER outcome the process
doc names (`ClaimContention`, `CorrelationBusy`, `OutOfOrderCompletion`, `CursorRaceLost`,
`ConsumerCrash`) is **not** a Zig error in this design, because the process doc itself states
each is a normal, expected control-flow outcome ("no error," "silent rollback," "released with
the transaction"). Representing them as enum return values (`?ClaimedCompletion`,
`ExecuteGuardOutcome`, `ApplyOutcome`) rather than `error{}` set members keeps that distinction
visible in the type system: a caller cannot accidentally `catch` its way past "another consumer
holds this correlation" as if it were a bug, because it never surfaces as a catchable error.

`CorrelationStalled` and `DuplicateCompletion` (process doc's `ON CONFLICT DO NOTHING` on
insert) are the Effects Worker's / Scheduler's concerns, not this consumer module's — see
"Dependencies" below.

## State transitions

`plat_effect_completion.status`: `PENDING -> APPLIED` (ORD-03, not this batch) or
`PENDING -> DEAD` (ORD-03's gap sweeper, not this batch). This batch's consumer never writes
`status` at all — `stubAlwaysDeferred` always rolls back, so every row this batch's consumer
touches is left exactly as it found it (`PENDING`). This is a deliberate, testable property:
running this batch's consumer loop against seeded `PENDING` rows must leave `status='PENDING'`
and `plat_correlation_cursor.applied_seq` unchanged for every row, proving the stub cannot
misapply anything ahead of ORD-03.

## Dependencies

- **Depends on:** `db` (pool.zig, per DB-02), `src/obs/logger.zig` (error logging, matching
  `effects/worker.zig`'s `logWorkerError` pattern), `src/obs/metrics.zig` (ORD-04 counter
  registration — extend the existing in-process registry, do not build a parallel one).
- **Must NOT depend on:** `src/engine/transition.zig` directly (the eventual ORD-03 `applyFn`
  drives the Catch-event Matcher through whatever re-entry interface
  `src/effects/worker.zig::reenterEffectResult` already establishes for effect results —
  reuse that entry point rather than inventing a second engine-re-entry path; this batch's stub
  has no engine dependency at all since it never applies anything).
- **DLQ integration note (flagged, non-blocking):** the process doc's step 9 says a
  dead-lettered correlation is "routed to the DLQ as one unit." `src/dlq/store.zig`'s
  `DlqItemType` enum is currently a closed set (`SERVICE_TASK`, `WEBHOOK`, `TIMER`) with no
  `EFFECT_CORRELATION`-shaped member. This batch does not touch DLQ (dead-lettering is ORD-03's
  step 9, not ORD-01/02/04's), but ORD-03's design will need either a new `DlqItemType` variant
  or a documented mapping onto an existing one — flagged here so ORD-03's design does not
  discover it late.

## Open questions

1. **Threading/scheduling mechanism for `consumer_count` independent loops.** This design
   specifies `runOneCycle`/`pollLoopStep` as the per-consumer unit of work but defers to
   BACKEND-DEV which existing background-thread mechanism (the one `src/scheduler/scheduler.zig`
   or `src/effects/worker.zig` already uses) runs `consumer_count` copies of it concurrently.
   Non-blocking: both existing modules already solve "run N independent polling loops," so this
   is a wiring choice, not an open design question about correctness.
2. **`ObservabilityCounters` windowing implementation.** ORD-04 AC3's "more than 50 per cent of
   claim attempts in one minute" needs a rolling window; this design points at
   `src/api/middleware/ratelimit.zig`'s existing sliding-window implementation as the pattern to
   reuse rather than specifying a new one, but does not verify that module's window shape is
   directly reusable outside the HTTP middleware context. Non-blocking — BACKEND-DEV should
   confirm reuse or fall back to a simple fixed 60s bucket, either satisfies ORD-04 AC3's
   literal wording.
3. **DLQ `DlqItemType` extension** — see "Dependencies" above. Non-blocking for THIS batch
   (ORD-01/02/04 never call into `dlq/store.zig`), flagged forward for ORD-03.
4. **`consumer_count` runtime reduction (ORD-04 AC3: "consumer_count is reduced by 2 with a
   floor of 2").** This implies `consumer_count` is a live, mutable value the poll-loop driver
   reads each cycle (or each restart), not a static startup constant the way `pool_size`
   (DB-02) is. This design's `OrderingConfig.consumer_count` is written as a plain field;
   BACKEND-DEV must decide the storage location for its live value (in-process atomic, matching
   `ObservabilityCounters`'s own `std.atomic.Value` pattern, is the natural fit and requires no
   new module). Non-blocking — the field exists in this design's config struct either way.

None of these four items leave an ORD-01/ORD-02/ORD-04 acceptance criterion uncovered — each is
a downstream implementation choice within a design decision this document already makes
(reuse an existing threading mechanism, reuse an existing rate-window mechanism, extend an
existing DLQ enum, store a mutable counter). Handoff `result.status` for the ORD-01/02/04
portion of this batch is **PASS**, with these four items carried forward as flagged,
non-blocking notes — the same honest-flagging pattern used in batches 0 and 1.
