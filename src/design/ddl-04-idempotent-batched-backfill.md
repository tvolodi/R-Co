# Module: ddl-04-idempotent-batched-backfill

**Requirement ID:** DDL-04
**Run ID:** WF02-batch-7-20260816 (Stage 16)
**Type:** Type E (backfill execution loop) + Type C (`plat_migration_state` migration)
**Extends:** DDL-03 (the three-phase generator's phase 2 — this design specifies the
backfill loop that consumes the generated phase-2 statement), DDL-01 / DDL-02 (the
pre-flight validating pass this backfill must not bypass), MIG-01 (the tenant fanout
that drives phase execution per tenant schema), DB-02 (one pooled connection per batch,
released between batches).
**Authoritative process source:** `docs/processes/system/platform-ddl-safety.md`
(`sys-platform-ddl-safety`, PW-05) — steps 10, 13 and the SLAs/Escalations table
(backfill batch duration, backfill stall) fully specify the loop semantics. This design
translates those into Zig module boundaries, error taxonomy, and the Type C migration
for `plat_migration_state`; it does not re-derive the loop from scratch.
**See also (referenced, not implemented here):** DDL-03 (the generator that produces the
phase-2 statement and would raise `NonIdempotentBackfill` at generation time; DDL-03 is
DRAFT — see Open questions §1), DDL-05 (the reserved-namespace rule that `plat_migration_state`
must satisfy by its `plat_` prefix), MIG-04/MIG-05/MIG-06 (the resume/status surface
`plat_migration_state` must serve).

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C — yes, for the schema.** DDL-04 requires recording per-batch backfill
   progress ("Rows updated per batch and remaining `IS NULL` rows per tenant are
   recorded in `plat_migration_state`") plus the resume state that DDL-04 AC1 depends
   on. `plat_migration_state` does **not** exist anywhere in the codebase yet
   (confirmed: `grep -r "plat_migration_state" src/ migrations/` matches only the
   process doc's prose, never a real table — the only migration-control table today is
   `platform.platform_migrations` from MIG-01, which records per-(migration, tenant)
   status but has no per-phase or per-batch-progress shape). One Type C migration YAML
   is produced alongside this document:
   `templates/specs/ddl-04-plat-migration-state.migration.yaml`.
2. **Type E — yes, for the loop.** The backfill loop itself (one transaction per batch,
   halving on timeout, stall detection and escalation, resume-against-`IS NULL`) is
   genuinely novel execution logic with no CRUD template shape, and it falls under
   lego-catalog.md's explicit "never templated" list: "Anything performance-sensitive
   (NFR benchmarks attached)" and the same reasoning the effects-worker precedent
   (`src/effects/worker.zig`, EXP-301) already established for the sibling polling-loop
   pattern. The `NonIdempotentBackfill` predicate guard is a validation-time concern
   that belongs beside the loop, not inside a template.

So this batch produces: **1 Type C migration YAML + 1 Type E design document** (this file).

## Existing pattern found and followed

Per the handoff's instruction to ground every design in a prior pattern:

| Aspect | Precedent | DDL-04 (this design) |
|---|---|---|
| Poll/loop with per-iteration transaction | `src/effects/worker.zig` `sweepOnce` (EXP-301) — each row processed on its own connection/transaction, never holding a connection across the sleep | Followed: each backfill batch runs on its own acquired connection in its own transaction, committed before the next batch's connection is acquired |
| Per-tenant DDL unit executed by the fanout | `src/platform/migration_fanout.zig` `DdlStep` — a caller-supplied `*const fn (conn, schema_name) anyerror!void` the fanout invokes inside the per-tenant transaction it opens | Followed as the wiring seam: phase-2's `runBackfill` is called **per tenant** by the migration runner, but the backfill loop opens its OWN per-batch transactions — it deliberately does NOT use the fanout's single `DdlStep` transaction (see "Why the loop is not a DdlStep" below) |
| Control-table progress recording | `platform.platform_migrations` (MIG-01) — per-(migration, tenant) status/error/run_id rows, partial index for resume | Extended: `plat_migration_state` adds the `phase` dimension and the batch-progress counters DDL-04 AC6 requires, with the same partial-index resume shape |
| Resumable against a stable predicate | `src/db/migrations.zig` `Migrations.runForSchema` — re-runs are safe because DDL is `IF NOT EXISTS`-guarded and DML is idempotent | Followed directly: the backfill predicate is always `WHERE <col> IS NULL`, so a re-run against an already-backfilled table updates 0 rows and terminates immediately (DDL-04 AC1) |

**Why the loop is not a `DdlStep` (the one precedent deliberately NOT followed):**
MIG-02/MIG-03's `DdlStep` contract is "run inside the per-tenant transaction this
module opens; must NOT open or commit its own transaction." DDL-04's loop **must** open
and commit one transaction per batch and must NOT run inside an outer transaction
(requirement body: "executed in a loop with one transaction per batch ... The loop SHALL
NOT run inside an outer transaction"). These are mutually exclusive. The backfill loop
therefore has its own entry point (`runBackfill`) that the migration runner calls
*instead of* wrapping in a `DdlStep`; the runner opens the per-tenant transaction only
for phases 1 and 3 (which remain `DdlStep`-shaped) and calls `runBackfill` as a
standalone, transaction-owning step between them. This is a deliberate, documented
departure, not an oversight.

## Module purpose

`src/platform/backfill.zig` (new) implements DDL-04's phase-2 backfill execution: given a
generated `UPDATE t SET c = <expr> WHERE c IS NULL AND ctid = ANY (... LIMIT $1)` statement
(the phase-2 statement DDL-03's generator produces), it executes that statement in a loop —
one transaction per batch, one pooled connection per batch — until an iteration reports
zero updated rows, recording per-batch progress into `plat_migration_state` and applying
the adaptive batch-size and stall policies. The module is the only component that may run
a generated backfill; its `validateGeneratedBackfill` guard is the enforcement point for
the `NonIdempotentBackfill` rejection (DDL-04 AC2) that runs **before** the first batch,
so a malformed generated statement never touches a tenant schema.

The module holds a database handle only while a batch is in flight. It records progress
row-by-row so an interrupted run (DDL-04 AC1) can be resumed by a later invocation of the
same function against the same `(migration_id, tenant_schema, phase)` key.

## Public interface

### `src/platform/backfill.zig` — the backfill loop and predicate guard

```zig
/// One generated backfill statement, produced by DDL-03's three-phase generator.
/// The generator and the guard share this descriptor so the guard can inspect
/// the predicate BEFORE any connection is opened.
pub const GeneratedBackfill = struct {
    migration_id: []const u8,
    tenant_schema: []const u8,
    table: []const u8,
    column: []const u8,
    /// The full generated phase-2 SQL text, e.g.
    /// "UPDATE t SET c = <expr> WHERE c IS NULL AND ctid = ANY (... LIMIT $1)".
    sql: []const u8,
    /// 1-based position of the statement within its migration file (reused from
    /// ddl_validate.StatementDescriptor.order so failure detail can name it).
    order: u32,
};

/// Adaptive batch-size policy. backfill_batch_size defaults to 5000 and is
/// bounded above by 50000 (DDL-04 body); per-tenant halving has a floor of 500
/// (DDL-04 AC4).
pub const BackfillConfig = struct {
    backfill_batch_size: u32 = 5000,
    batch_size_upper_bound: u32 = 50000,
    batch_size_floor: u32 = 500,
    batch_timeout_ms: u64 = 5_000,       // DDL-04 AC4: a batch > 5 s halves the next
    stall_threshold_iterations: u32 = 10, // DDL-04 AC5: ten zero-progress iterations
    lock_timeout_s: u8 = 3,              // DDL-03 AC6: every phase statement
    statement_timeout_s: u8 = 60,        // DDL-03 AC6
};
```

```zig
/// Outcome of a single runBackfill invocation for one (migration, tenant, phase).
pub const BackfillResult = struct {
    migration_id: []const u8,
    tenant_schema: []const u8,
    rows_updated_total: i64,   // cumulative across all batches this run
    rows_remaining: i64,       // remaining IS NULL rows at loop end
    batches_run: u64,
    final_batch_size: u32,     // the batch size used for the last batch
    stalled: bool,             // true when DDL-04 AC5 fired and the loop stopped
    status: MigrationPhaseStatus, // applied | failed (see state transitions)
};

pub const BackfillError = error{
    NonIdempotentBackfill, // DDL-04 AC2 — predicate not IS NULL-bounded
    LockTimeout,           // DDL-03 AC6 — lock_timeout exceeded on a batch
    StatementTimeout,      // DDL-03 AC6 — statement_timeout exceeded on a batch
    BackfillIncomplete,    // phase 3 VALIDATE CONSTRAINT found a violating row
    PoolExhausted,         // DB-02 — no pooled connection for a batch
    PersistenceFailed,     // query/exec or progress-write failure
    OutOfMemory,
};
```

```zig
/// Validate the generated phase-2 predicate. Rejects any generated backfill whose
/// predicate is not bounded by `IS NULL` with NonIdempotentBackfill (DDL-04 AC2).
/// Pure: no connection, no clock, no environment read — same purity contract as
/// ddl_validate.zig.
pub fn validateGeneratedBackfill(
    backfill: GeneratedBackfill,
    batch_size: u32,
) BackfillError!u64;

/// Execute the generated backfill for one tenant schema. Opens its own per-batch
/// transactions on per-batch pooled connections. Never called inside an outer
/// transaction (see "Why the loop is not a DdlStep"). Returns when an iteration
/// reports zero updated rows, or when the stall policy fires (DDL-04 AC5).
pub fn runBackfill(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    backfill: GeneratedBackfill,
    config: BackfillConfig,
) BackfillError!BackfillResult;

/// Record one batch's progress into plat_migration_state (DDL-04 AC6), on the
/// SAME connection/transaction as the batch, so progress and batch commit are atomic.
pub fn recordBatchProgress(
    conn: anytype,
    migration_id: []const u8,
    tenant_schema: []const u8,
    phase: []const u8,
    rows_updated: i64,
    rows_remaining: i64,
    batch_ms: u64,
) BackfillError!void;
```

### `src/platform/migration_fanout.zig` — the seam this design fills (phase 2)

The fanout's `DdlStep` shape stays untouched for phases 1 and 3. Phase 2 is wired as a
**separate per-tenant call** made by the migration runner between the phase-1 `DdlStep`
and the phase-3 `DdlStep`:

```zig
/// Phase-2 wiring seam (designed, not implemented here): the runner calls
/// backfill.runBackfill directly, NOT through DdlStep, because the loop must
/// own its per-batch transactions. Signature shown so BACKEND-DEV knows the
/// runner's call site; it is not a new export of migration_fanout.zig.
// runner pseudocode for one tenant:
//   phase1: fanout.runFanout(..., ddlStepPhase1)   -- existing DdlStep, unchanged
//   phase2: backfill.runBackfill(pool, generatedPhase2, config)   -- NEW, owns txns
//   phase3: fanout.runFanout(..., ddlStepPhase3)   -- existing DdlStep, unchanged
```

## Connection acquisition (DB-02 — one pooled connection per batch, released between batches)

`runBackfill` for one tenant:

1. `pool.acquire()` — one connection for the CURRENT batch only.
2. `conn.begin()`.
3. Run the generated phase-2 SQL with the current `backfill_batch_size` bound as `$1`.
4. `conn.query` returns the number of updated rows; `recordBatchProgress` writes the
   batch's `rows_updated`, `rows_remaining`, `batch_ms` into `plat_migration_state` on
   the same connection/transaction.
5. `conn.commit()` — the batch is durable and its lock (`ROW EXCLUSIVE` on the table,
   DDL-04 AC3) is released.
6. `pool.release(conn)` — **before** the next batch is planned (DB-02: never hold a
   pooled connection idle between batches; this mirrors `effects/worker.zig`'s
   GH-654/ISS-0649 lesson).
7. Repeat until an iteration reports 0 updated rows, or the stall policy fires.

The `ROW EXCLUSIVE` lock is the lock the `UPDATE` statement itself takes; it is released
at `COMMIT` of the batch and never spans two batches (DDL-04 AC3). The loop holds no
connection and no transaction between batches.

## Data flow

```
DDL-03 generator (DRAFT, referenced)
        |
        |  emits phase-2 statement: UPDATE t SET c=<expr> WHERE c IS NULL AND
        |  ctid = ANY (ARRAY(SELECT ctid FROM t WHERE c IS NULL LIMIT $1))
        v
backfill.validateGeneratedBackfill(backfill, batch_size)     [DDL-04 AC2]
        |  predicate is NOT "IS NULL"-bounded?
        |  -> NonIdempotentBackfill; NO statement executed; file set rejected
        |  predicate bounded
        v
backfill.runBackfill(pool, backfill, config)                  [per tenant]
   loop (no outer transaction):
     acquire conn -> begin ->
       run phase-2 SQL (LIMIT $1 = current batch size)
       recordBatchProgress(...) into plat_migration_state      [DDL-04 AC6]
       -> rows_updated == 0 ?  loop ends
       -> batch_ms > 5000 ?      next batch size halved (floor 500)  [AC4]
       -> 10 consecutive 0-row iterations ?  stop; escalate (AC5)
     commit -> release conn                                     [AC3]
        |
        v
   BackfillResult { rows_updated_total, rows_remaining, stalled, ... }
        |
        v
   (runner then proceeds to phase 3: VALIDATE CONSTRAINT + SET NOT NULL)
```

## Error taxonomy

```zig
pub const BackfillError = error{
    NonIdempotentBackfill, // AC2 — generated predicate not IS NULL-bounded; pure guard
    LockTimeout,           // AC3/DDL-03 AC6 — batch could not take ROW EXCLUSIVE in 3 s
    StatementTimeout,      // DDL-03 AC6 — batch exceeded 60 s statement_timeout
    BackfillIncomplete,    // phase 3 VALIDATE CONSTRAINT found a violating row (DDL-03 AC5)
    PoolExhausted,         // DB-02 — no pooled connection for a batch
    PersistenceFailed,     // query/exec or progress-write failure
    OutOfMemory,
};
```

Deliberately narrow, matching `EffectQueueError`'s precedent. The adaptive actions (halve
batch size, detect a stall, escalate) are **control-flow decisions inside `runBackfill`**,
not error returns: a slow batch is a normal condition DDL-04 AC4 handles by shrinking the
next batch, and a stalled loop is handled by stopping and returning `stalled = true`
(DDL-04 AC5) so the caller escalates — neither is a thrown error. `BackfillIncomplete` is
listed because phase 3 (DDL-03, a sibling requirement) treats it as the signal to re-run
phase 2 for that tenant; this module does not raise it, but its design must not make that
recovery impossible.

## State transitions

`plat_migration_state` per `(migration_id, tenant_schema, phase)` row:

```
PENDING -> RUNNING -> APPLIED        (normal: loop ends with 0 remaining rows)
PENDING -> RUNNING -> FAILED         (LockTimeout / StatementTimeout / PersistenceFailed)
RUNNING -> RUNNING                   (each committed batch: rows_updated_total += n,
                                      rows_remaining = n, batch_ms recorded, AC6)
RUNNING -> FAILED                    (stall policy fires — AC5; escalation recorded)
```

Resume (DDL-04 AC1): a run interrupted at batch 40 of 100 leaves the row in `RUNNING`
with `rows_updated_total` and `rows_remaining` at their last-committed values. A later
`runBackfill` invocation for the same key resumes the loop; because the predicate is
`WHERE c IS NULL`, rows already backfilled are skipped and the end state is identical to
an uninterrupted run. No "restart from scratch" flag exists — the predicate is the only
source of truth for what remains.

## Dependencies

- **Depends on:** `db` (`pool.zig`, per DB-02 — one pooled connection per batch),
  `src/obs/logger.zig` (escalation/error logging, matching `effects/worker.zig`'s
  `logWorkerError` pattern), `src/obs/alerting` (the Platform Admin escalation on stall,
  DDL-04 AC5 — same hook `obs-06-alerting-hooks.md` defines), and the new
  `plat_migration_state` table (Type C migration in this batch).
- **Must NOT depend on:** `src/db/migrations.zig` or `src/platform/migration_fanout.zig`
  transaction boundaries (the loop owns its transactions); `std.time` reads at
  validation time (the `NonIdempotentBackfill` guard is pure, matching
  `ddl_validate.zig`'s purity contract); `ddl_namespace.zig` (the reserved-prefix rule is
  already enforced at validation time by DDL-05; the backfill only ever writes the
  `plat_`-prefixed control table the migration creates).
- **DLQ/event integration:** the escalation on stall and on `BackfillIncomplete` follows
  the existing `EXECUTION_MIGRATION_*` event conventions already seeded for the platform
  migration surface (`src/design/mig-02-mig-03-platform-migration-fanout.md`); no new
  event type is introduced by this design.

## Acceptance-criterion coverage (DDL-04)

| AC | Design location |
|---|---|
| AC1 (interrupt/resume, identical end state) | State transitions "Resume" + `runBackfill` loop + `plat_migration_state` `(migration_id, tenant_schema, phase)` key and `RUNNING` status; Type C migration's resume index |
| AC2 (`NonIdempotentBackfill`, no statement executed) | `validateGeneratedBackfill` (pure guard, runs before any connection); `BackfillError.NonIdempotentBackfill` |
| AC3 (`ROW EXCLUSIVE`, commit before next batch, no txn spans two batches) | Connection acquisition §; the `UPDATE` takes `ROW EXCLUSIVE`, `commit()` per batch, `release` before next batch |
| AC4 (batch > 5 s halves next batch, floor 500) | `BackfillConfig.batch_timeout_ms` / `batch_size_floor`; adaptive halving decision in `runBackfill` |
| AC5 (ten zero-progress iterations → stop + escalate with remaining count) | `BackfillConfig.stall_threshold_iterations`; `BackfillResult.stalled`; escalation via alerting hook |
| AC6 (rows updated per batch + remaining IS NULL per tenant recorded) | `recordBatchProgress` → `plat_migration_state` columns `rows_updated_total`, `rows_remaining`, `last_batch_rows`, `last_batch_ms`; Type C migration |

## Open questions

1. **DDL-03 (the generator) is DRAFT and not yet implemented.** This design specifies the
   consumer side of the phase-2 statement and the `GeneratedBackfill` descriptor it
   expects, but the generator that emits the statement is DDL-03's own handoff. If DDL-03's
   generator emits a different descriptor shape (e.g. carries the column default expression
   separately), `validateGeneratedBackfill`'s predicate inspection must adapt. Non-blocking
   for THIS handoff — the design defines the contract both sides converge on, and
   BACKEND-DEV can implement `backfill.zig` against the descriptor here.
2. **Escalation mechanism on stall (AC5).** The alerting hook (`src/obs/alerting`) is
   referenced rather than re-derived; whether the stall escalation is a page (PagerDuty-
   style) or a log + event depends on the existing alerting channel. Non-blocking —
   BACKEND-DEV wires `runBackfill`'s `stalled` return to whatever `obs-06-alerting-hooks.md`
   already provides.

None of these leave a DDL-04 acceptance criterion uncovered. Handoff `result.status` for
the DDL-04 portion is **PASS**.
