# Module: ord-03-sequence-order-guard-gap-sweeping

**Requirement ID:** ORD-03
**Run ID:** WF02-batch-7-20260816 (Stage 16)
**Type:** Type E only (no Type C — the two tables this design reads/writes already exist
from the ORD-01/ORD-04 migrations, and the DLQ item-type extension is code-only)
**Extends:** the correlated effect re-entry ordering family (`src/ordering/mod.zig`,
`src/ordering/cursor.zig`, `src/ordering/consumer.zig`, `src/ordering/observability.zig`,
designed in `src/design/ord-01-02-04-correlated-effect-reentry.md` and shipped for
ORD-01/02/04). That design explicitly reserved the seam this batch fills: `applyFn` on
`ConsumerRunConfig` (currently `stubAlwaysDeferred`), `readOrInitCursor` (declared, not
implemented), the `ApplyOutcome` enum, and the flagged DLQ `DlqItemType` extension.
**Authoritative process source:** `docs/processes/system/effect-reentry-ordering.md`
(`sys-effect-reentry-ordering`, PW-07) — steps 1, 4, 5, 6, 7, 9 and the Business Rules
(Order guard scope, Apply and cursor are atomic, Cursor advance is conditional, No error
on out-of-order, Dead-lettering is per correlation, Duplicate completions) fully specify
this batch. This design translates them into the concrete `applyFn` and the gap sweeper;
it does not re-derive the process from scratch.
**See also:** OBS-05 (the dead-letter queue receiving a swept correlation as one unit),
ORD-04 (the lag/contention metrics this batch's sweeper and escalation co-exist with),
PAR-01 (the event log the `EXECUTION_EFFECT_APPLIED` append targets).

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C? No.** No table or column is added, altered, or removed by ORD-03:
   - `plat_effect_completion` (ORD-01 migration 1145) already has the `(correlation_id,
     sequence_no)` UNIQUE constraint that makes AC6's `ON CONFLICT DO NOTHING` work, and
     its `status` CHECK already admits `PENDING`, `APPLIED`, `DEAD` (so the sweeper's
     `PENDING -> DEAD` transition needs no schema change).
   - `plat_correlation_cursor` (ORD-04 migration 1146) already has `applied_seq bigint
     DEFAULT 0` and `correlation_id` as PK (so the order guard's read and the
     conditional advance need no schema change).
   - The DLQ (`dead_letter_queue`, `item_type TEXT NOT NULL` from
     `021_obs05_dead_letter_context.sql`) has **no CHECK constraint** on `item_type`, so
     adding the `EFFECT_CORRELATION` value is a code change to `src/dlq/store.zig`'s
     `DlqItemType` enum — not a migration. (Confirmed: `grep -n "item_type" migrations/`
     shows only the ALTER + backfill in 021; no CHECK.)
2. **Type E — yes.** The order guard, the atomic apply+cursor-advance, the conditional
   update, and the 60 s gap sweeper with per-correlation dead-lettering are genuinely
   novel engine-side logic — lego-catalog.md's explicit "engine kernel, transition logic,
   deterministic replay" bucket, and the same classification batch-2 already gave the
   sibling consumer logic.

So this batch produces: **1 Type E design document** (this file) and **0 parameter files**.

## Existing pattern found and followed

Per the handoff's instruction to ground every design in a prior pattern:

| Aspect | Precedent | ORD-03 (this design) |
|---|---|---|
| Consumer apply seam | `src/ordering/consumer.zig` `ConsumerRunConfig.applyFn` + `ApplyOutcome` (designed and shipped for ORD-01/02/04, currently `stubAlwaysDeferred`) | Followed directly: this batch supplies the real `applyFn` (`applyCompletion`) with the exact `ApplyOutcome` contract the ORD-01/02/04 design fixed — `.applied`, `.deferred`, `.apply_failed` |
| Cursor read/init | `src/ordering/cursor.zig` `readOrInitCursor` (declared in the ORD-01/02/04 design as the extension point, not implemented) | Implemented here: read `applied_seq`, insert at 0 if absent (`MissingCursorRow` recovery), all under the ORD-02 advisory lock already held |
| Atomic apply+cursor advance | `src/effects/worker.zig::reenterEffectResult` (engine re-entry happens in the same transaction as the event append) | Followed: the engine apply and the conditional cursor advance commit or roll back together (AC4) |
| Dead-letter path | `src/dlq/store.zig` `DlqItemType` enum (`SERVICE_TASK`, `WEBHOOK`, `TIMER`) + `dead_letter_queue` | Extended: add `EFFECT_CORRELATION` variant + `entryTypeForItemType`/`itemTypeToWire` mapping; this is the exact extension the ORD-01/02/04 design flagged as open question 3 |
| 60 s sweeper cadence | `src/scheduler/scheduler.zig` (existing background timer the ORD-01/02/04 design already assigned the lag sweep to) | Followed: the gap sweeper runs on the SAME 60 s cadence as ORD-04's lag computation — no new timer thread |

**Deliberately NOT re-derived:** the claim guard (ORD-01), the execute guard (ORD-02),
and the parallelism/lag surface (ORD-04) are shipped and untouched. This batch only fills
the seams those designs reserved.

## Module purpose

`src/ordering/` gains ORD-03's two responsibilities, filling the seams the ORD-01/02/04
design reserved:

1. **The order guard + atomic apply** (process steps 4-7): for a claimed completion whose
   execute guard is held, apply it only when `sequence_no = applied_seq + 1`; advance the
   correlation's cursor with the conditional update; commit the apply and the advance as
   one transaction. An out-of-order completion rolls back silently with no error and no
   retry increment, leaving the row `PENDING` (AC1); a cursor race (0 rows updated) rolls
   back and the completion is re-claimed (AC3); a typed engine error rolls back so applied
   state and `applied_seq` cannot diverge (AC4).
2. **The gap sweeper** (process step 9): on the scheduler's 60 s cadence, find
   correlations whose successor has been `PENDING` longer than `gap_timeout_seconds`
   (default 300) while its predecessor is absent, move every `PENDING` row of that
   correlation to `DEAD` as one unit, and route it to the dead-letter queue as one DLQ
   entry naming the `correlation_id` and every unapplied `sequence_no` (AC5).

It also owns the Effects-Worker-side `ON CONFLICT DO NOTHING` insert discipline (AC6):
the existing `INSERT` path the Effects Worker uses to record a completion must use the
clause so a retried insert of the same `(correlation_id, sequence_no)` is absorbed.

## Public interface

### `src/ordering/cursor.zig` — cursor read/init/advance (fills the declared seams)

```zig
/// Implemented now (declared in the ORD-01/02/04 design): read applied_seq for
/// correlation_id from plat_correlation_cursor, inserting a fresh row at
/// applied_seq=0 if absent (process doc's MissingCursorRow recovery). MUST be
/// called on the SAME connection/transaction that already holds ORD-02's
/// per-correlation advisory lock, so applied_seq cannot move between this read
/// and the advance.
pub fn readOrInitCursor(
    allocator: std.mem.Allocator,
    conn: anytype,
    correlation_id: []const u8,
) mod.OrderingError!i64;

/// The conditional cursor advance (process step 6 / ORD-03 body):
///   UPDATE plat_correlation_cursor SET applied_seq = $2
///   WHERE correlation_id = $1 AND applied_seq = $2 - 1
/// Returns the number of rows updated (0 or 1). A 0 result is CursorRaceLost —
/// another transaction advanced the cursor; the caller rolls back and re-claims.
pub fn advanceCursor(
    allocator: std.mem.Allocator,
    conn: anytype,
    correlation_id: []const u8,
    new_applied_seq: i64,
) mod.OrderingError!u64;
```

### `src/ordering/consumer.zig` — the real `applyFn` (replaces `stubAlwaysDeferred`)

```zig
/// ORD-03's implementation of ConsumerRunConfig.applyFn. Given a claimed row with
/// the execute guard already held (the ORD-01/02/04 contract), applies it under the
/// order guard and advances the cursor in one transaction. The caller
/// (runOneCycle, unchanged from ORD-01/02/04) already owns the connection and the
/// transaction; this function returns the ApplyOutcome and the caller commits or
/// rolls back accordingly.
pub fn applyCompletion(
    allocator: std.mem.Allocator,
    conn: anytype,
    claim: mod.ClaimedCompletion,
) mod.OrderingError!ApplyOutcome;
```

`ApplyOutcome` is unchanged from the ORD-01/02/04 design; this batch's function now
returns all three values meaningfully:

| Outcome | When | Caller action |
|---|---|---|
| `.applied` | order guard passed, engine apply succeeded, cursor advanced to `sequence_no` | COMMIT; `status -> 'APPLIED'` (same transaction); append `EXECUTION_EFFECT_APPLIED` |
| `.deferred` | `sequence_no != applied_seq + 1` (AC1) or the cursor advance returned 0 rows (AC3) | ROLLBACK silently; no error, no retry increment; row stays `PENDING` |
| `.apply_failed` | the engine apply raised a typed error (AC4) | ROLLBACK; retry policy governs the next attempt; row stays `PENDING` |

### `src/ordering/sweeper.zig` — the 60 s gap sweeper (new file in the ordering family)

```zig
/// One correlation the gap sweeper dead-lettered as a unit.
pub struct SweptCorrelation = struct {
    correlation_id: []u8,
    unapplied_sequence_nos: []i64, // every PENDING sequence_no of the correlation
    pending_row_count: u64,

    pub fn deinit(self: SweptCorrelation, allocator: std.mem.Allocator) void;
};

/// Find correlations whose successor has been PENDING longer than
/// gap_timeout_seconds while its predecessor (applied_seq + 1) is absent, then —
/// per correlation, in ONE transaction — set every PENDING row to 'DEAD' and return
/// the correlation for DLQ routing. AC5: "every PENDING row of that correlation moves
/// to status = 'DEAD' and is routed to the dead letter queue as one unit."
pub fn sweepStalledCorrelations(
    allocator: std.mem.Allocator,
    conn: anytype,
    gap_timeout_seconds: u32,
) mod.OrderingError![]SweptCorrelation;
```

### `src/dlq/store.zig` — the flagged `EFFECT_CORRELATION` extension (code-only)

```zig
// DlqItemType gains one member:
//   EFFECT_CORRELATION,
// with the existing closed-set mechanics extended consistently:
//   itemTypeToString:  .EFFECT_CORRELATION => "EFFECT_CORRELATION"
//   itemTypeFromString: "EFFECT_CORRELATION" => .EFFECT_CORRELATION
//   entryTypeForItemType: .EFFECT_CORRELATION => "effect_correlation_failed"
// A swept correlation is routed as ONE dead_letter_queue row whose
// processor_metadata JSONB carries { correlation_id, unapplied_sequence_nos:
// [ ... ], pending_row_count } (AC5: the missing emit is identifiable without
// querying the completion table).
```

### Effects Worker insert discipline (AC6 — code, not schema)

The Effects Worker's completion insert (`INSERT INTO plat_effect_completion
(correlation_id, sequence_no, status, payload, received_at)`) MUST append
`ON CONFLICT (correlation_id, sequence_no) DO NOTHING` (process step 1), so a retried
effect does not duplicate. The UNIQUE constraint already exists (ORD-01 migration 1145);
this batch only ensures the insert path uses the clause.

## Connection acquisition

`applyCompletion` runs on the SAME connection/transaction `runOneCycle` already opened
for the claim + execute guard (ORD-01/02/04 contract — the row lock and the advisory
lock must span the apply). The gap sweeper acquires its own connection for the 60 s pass,
runs the per-correlation DEAD transition and returns the swept set, then releases the
connection BEFORE the DLQ insert (the DLQ insert runs on a fresh connection, so the
sweep's connection is never held across the DLQ write). This mirrors the
`effects/worker.zig` fetch/process split and DB-02's one-pooled-connection discipline.

## Data flow

```
BPM Consumer runOneCycle (unchanged from ORD-01/02/04)
  claim (ORD-01) -> execute guard (ORD-02) ->
  applyCompletion(conn, claim)                         [this batch]
     readOrInitCursor(conn, correlation_id) -> applied_seq
        |  sequence_no != applied_seq + 1 ?
        |     -> .deferred ; caller ROLLBACKs silently (AC1)
        |  sequence_no == applied_seq + 1
        v
     engine apply (via effects/worker.zig reenterEffectResult path)
        |  typed engine error ?  -> .apply_failed ; ROLLBACK (AC4)
        v
     advanceCursor(conn, correlation_id, sequence_no)   [conditional UPDATE]
        |  0 rows ?  -> .deferred (CursorRaceLost) ; ROLLBACK + re-claim (AC3)
        |  1 row
        v
     status -> 'APPLIED' + append EXECUTION_EFFECT_APPLIED (same txn)
        |  .applied ; caller COMMITs (AC2: 5 then 6, engine observes order)

Scheduler 60 s cadence:
  sweepStalledCorrelations(conn, gap_timeout_seconds)   [this batch]
     find PENDING successor older than gap_timeout while predecessor absent
        |  per correlation, one txn: status PENDING -> DEAD (ALL rows)
        v
     SweptCorrelation -> dlq.store (EFFECT_CORRELATION row, one unit, AC5)

Effects Worker insert path:
  INSERT ... ON CONFLICT (correlation_id, sequence_no) DO NOTHING   [AC6]
```

## Error taxonomy

The ORD-01/02/04 design already fixed `OrderingError = error{
PoolExhausted, PersistenceFailed, OutOfMemory }` and established the principle that
process-doc "failure" names are enum outcomes, not Zig errors. This batch follows that
exactly:

| Process-doc name | Representation here | Why not a Zig error |
|---|---|---|
| `OutOfOrderCompletion` (AC1) | `ApplyOutcome.deferred` | "silent ROLLBACK with no error" is the requirement's own wording |
| `CursorRaceLost` (AC3) | `ApplyOutcome.deferred` (advanceCursor returned 0) | "ROLLBACK and re-claim" is normal control flow |
| `ApplyFailed` (AC4) | `ApplyOutcome.apply_failed` | the typed engine error is carried to the caller, then rolled back |
| `CorrelationStalled` (AC5) | `SweptCorrelation` return value | the sweeper's whole job; not an error condition |
| `DuplicateCompletion` (AC6) | `ON CONFLICT DO NOTHING` (0 rows) | absorbed insert, no error |
| `MissingCursorRow` | `readOrInitCursor` inserts at 0 | recovery, not an error |

No new member is added to `OrderingError`. A `0 rows` return from `advanceCursor` is a
value, not an error, so the caller cannot accidentally `catch` it as if a double-apply
were a bug.

## State transitions

```
plat_effect_completion.status:
  PENDING -> APPLIED   (applyCompletion .applied; same txn as cursor advance, AC2/AC4)
  PENDING -> DEAD      (gap sweeper, per correlation as one unit, AC5)

plat_correlation_cursor.applied_seq:
  n -> n+1             (only via the conditional advance
                        WHERE applied_seq = $2 - 1; monotonic, AC2/AC3)
```

Both transitions are written in the same transaction as the state they depend on, so
applied state and `applied_seq` cannot diverge (AC4). A row that is `DEAD` is never
re-claimed (the claim query filters `status = 'PENDING'`), and a swept correlation's
cursor row is left at its last applied value (dead-lettering does not move the cursor).

## Dependencies

- **Depends on:** `src/ordering/mod.zig` (shared types/constants — `ClaimedCompletion`,
  `OrderingError`, `OrderingConfig.gap_timeout_seconds`), `src/ordering/cursor.zig` /
  `consumer.zig` (the seams this batch fills), `src/effects/worker.zig::reenterEffectResult`
  (the engine re-entry path the apply drives — reused, not reinvented), `src/dlq/store.zig`
  (extend `DlqItemType`), `src/scheduler/scheduler.zig` (the existing 60 s cadence the gap
  sweeper hooks onto), `src/obs/logger.zig` + `src/obs/metrics.zig` (sweeper logging and
  the AC5 escalation surface shared with ORD-04).
- **Must NOT depend on:** `src/engine/transition.zig` directly (the apply re-enters the
  engine through the `reenterEffectResult` path the effects worker already establishes,
  per the ORD-01/02/04 design's dependency note); `src/platform/ddl_validate.zig` or any
  migration-runner code (unrelated family).
- **Consistency with shipped siblings:** the ORD-01/02/04 design's `stubAlwaysDeferred`
  was deliberately written to never misapply anything before this batch; replacing it
  with `applyCompletion` must not change `runOneCycle`'s transaction ownership. This
  design preserves the ORD-01/02/04 contract that `.deferred` -> rollback, `.applied` /
  `.apply_failed` -> commit/rollback is decided by the caller.

## Acceptance-criterion coverage (ORD-03)

| AC | Design location |
|---|---|
| AC1 (seq 6 before 5: not applied, silent rollback, no retry increment, stays PENDING) | `applyCompletion` order guard (`sequence_no != applied_seq + 1` -> `.deferred`); caller ROLLBACK silently; row stays `PENDING` |
| AC2 (seq 5 then applied; applied_seq advances; seq 6 applied next; engine observes 5 before 6) | `.applied` path: apply + `advanceCursor` to 5 in one txn; next claim reads applied_seq 5 and admits 6 |
| AC3 (conditional cursor update 0 rows -> rollback + re-claim; double-apply impossible) | `advanceCursor`'s `WHERE applied_seq = $2 - 1`; a 0-row result is `ApplyOutcome.deferred` and the caller re-claims |
| AC4 (apply raises typed engine error -> rollback; state and cursor cannot diverge) | `.apply_failed` path: engine apply and cursor advance share the transaction; error -> ROLLBACK of both |
| AC5 (successor PENDING > gap_timeout_seconds while predecessor absent -> sweeper moves ALL PENDING rows of that correlation to DEAD, DLQ as one unit) | `sweepStalledCorrelations` on the 60 s cadence; per-correlation one-transaction DEAD transition + one `EFFECT_CORRELATION` DLQ row carrying every unapplied sequence_no |
| AC6 (Effects Worker re-inserts existing (correlation_id, sequence_no) -> ON CONFLICT DO NOTHING, no second apply) | Effects Worker insert path uses `ON CONFLICT (correlation_id, sequence_no) DO NOTHING` (UNIQUE constraint already from ORD-01 migration 1145) |

## Open questions

1. **DLQ `entry_type` legacy column backfill.** `dead_letter_queue.entry_type` (the
   pre-021 column whose values `service_task_failed`/`webhook_failed`/`timer_failed` feed
   `item_type`) has no `effect_correlation_failed` value. This batch writes
   `item_type = 'EFFECT_CORRELATION'` directly on new DLQ rows and does not need to touch
   `entry_type`; whether the OBS-05 inspect/retry surface filters on `item_type` or
   `entry_type` must be confirmed so swept correlations appear there. Non-blocking — the
   `item_type` value is authoritative per `021_obs05_dead_letter_context.sql`.
2. **AC5's "predecessor is absent" predicate.** The sweeper must distinguish "successor
   waiting on a missing predecessor" from "successor simply behind on a slow correlation".
   The process doc's wording (PENDING older than `gap_timeout_seconds` while its
   predecessor is absent) is implemented as: the correlation's cursor `applied_seq` is
   behind the lowest PENDING `sequence_no` and that row is older than the timeout. The
   exact SQL predicate is a BACKEND-DEV implementation detail within that rule; flagged
   so TEST-DESIGNER seeds both cases distinctly (missing predecessor vs slow-but-present).

None of these leave an ORD-03 acceptance criterion uncovered. Handoff `result.status` for
the ORD-03 portion is **PASS**.
