# Module: par-05-online-partition-conversion

**Requirement ID:** PAR-05
**Run ID:** WF02-batch-4-20260811 (Stage 16)
**Covers:** PAR-05
**Extends:** none (PAR-05 has no `Extends:` line in its body)
**See (from PAR-05's own body):** PAR-01 (the target shape this conversion produces), PAR-03
(how `events_legacy` finally ages out), PAR-04 (the CHECK-before-attach discipline the swap's
new partitions must also honour), DDL-04 (the batched-backfill discipline PAR-05 explicitly
reuses)

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** The requirement's surface is a migration-shaped operation (schema rename swap,
   new `plat_event_idempotency` table), but its actual content — a parallel-table build,
   per-month batched backfill with resumable `ON CONFLICT DO NOTHING`, a coverage-gap validator,
   a timed rename-swap with row-count reconciliation and inverse-rename rollback, and a retention
   handoff to `events_legacy` — has no representation in `templates/specs/migration.template.yaml`
   (a flat `tables:`/`CREATE TABLE`/`ALTER TABLE` list). This is the same shape of mismatch PAR-01
   documented for the same reason in `src/design/par-01-monthly-range-partitioning.md`'s own
   Classification rationale — one online DDL conversion, not a set of independent flat table
   edits a template can parametrise.
2. **Type A / Type D / Type B?** No HTTP route, no React Flow node, no admin page.
3. **Type E — yes.** A structurally novel, ordered multi-phase operation (validate coverage →
   create parent → backfill in month-windows → catch-up replay → timed rename-swap → row-count
   reconciliation → retention handoff) that BACKEND-DEV must hand-write as a runnable procedure
   (migration file plus, per Open questions §1, likely a companion CLI/tool entry point — this is
   not a single `zig build migrate` DDL statement set the way PAR-01's from-scratch schema build
   was), following this prose design rather than running codegen. Per `templates/lego-catalog.md`:
   "When in doubt, prefer Type E."

This design specifies the conversion's SQL/procedural shape in enough detail for BACKEND-DEV to
implement without further schema decisions of its own, per the same reading of
`docs/anti-patterns.md`'s "Do NOT make database schema decisions outside a Type C migration YAML"
caveat that PAR-01's design already established: the caveat's intent is satisfied by a design
artefact BACKEND-DEV implements from, for a migration too structurally novel for the Type C
template. No fenced code block below exceeds the linter's 40-line cap.

## Scoping note — read this before implementing

**This design assumes the target environment already has `events`/`events_archive` built
UNPARTITIONED and POPULATED by `001_event_store.sql`/`003_event_archive.sql` (the pre-PAR-01
shape) — i.e. it addresses exactly the "hypothetical long-lived `bpm_dev`/production database
that already has migrations applied and real rows in `events`" scenario PAR-01's design flagged
in its own Open questions §1 and explicitly declined to solve.** PAR-01's migration
(`1147_par01_events_partitioning.sql`) already shipped in this run's prior batch (RELEASED) and
takes the from-scratch path (guarded `DROP`/`CREATE PARTITION BY RANGE`, raising
`object_not_in_prerequisite_state` if `events` is non-empty) — it does NOT perform PAR-05's
online conversion and is not modified by this design. **PAR-05 is therefore not currently
reachable by this codebase's own test infrastructure**, which re-applies the full migration set
from `001` onward on every fresh `bpm_test` provisioning (per `docs/guides/test_infrastructure_guide.md`)
and so always hits PAR-01's from-scratch path with zero pre-existing rows — never PAR-01's
`object_not_in_prerequisite_state` guard, and never a scenario where PAR-05's conversion has
anything to convert. This is not a defect in this design: PAR-05's own body is unambiguous that
it is "the one-time conversion of an EXISTING `events` table" — a real production/`bpm_dev`
upgrade path, not a step the automated test suite exercises end-to-end today. See Open questions
§1 for how TEST-DESIGNER should handle this (a synthetic pre-partition fixture, not a real
`bpm_test` provisioning run) and Open questions §2 for the resulting migration-ordering question
this creates against `1147`.

## Module purpose

Define the operation that converts an already-populated, unpartitioned `events` table (the shape
`001_event_store.sql` originally created, and the shape any pre-PAR-01 production/`bpm_dev`
database still has) into PAR-01's partitioned target shape, without taking `events` offline:
build a new partitioned parent (`events_part`) alongside the live table, backfill historical rows
in resumable one-month/one-transaction windows, create and populate `plat_event_idempotency`
before the cutover, replay the catch-up window, and swap the two tables by rename inside one
short, lock-timeout-bounded transaction — with row-count reconciliation and an inverse-rename
rollback if the swap's own bookkeeping ever disagrees.

## Data flow diagram

```
Operator/ORCH triggers conversion (out of band — see Open questions §1 for the entry point)
        |
        v
Step 1: PartitionRangeGap coverage validation
        |   SELECT min(created_at), max(created_at) FROM events
        |   for each calendar month in [min, max + lead_horizon]:
        |     confirm a target partition WOULD exist once events_part is built
        |   -- no partition attached yet at this point; this validates the PLANNED
        |      month grid (same monthRange()/addMonthsUs() arithmetic
        |      src/scheduler/partition_maintenance.zig already uses) covers every
        |      populated month with no gap, before any DDL runs.
        |   gap found -> PartitionRangeGap raised, STOP (no backfill starts)
        v
Step 2: CREATE TABLE events_part (LIKE events INCLUDING DEFAULTS INCLUDING IDENTITY)
        |   PARTITION BY RANGE (created_at)
        |   -- live `events` continues accepting appends unchanged; events_part has
        |      no attached partitions yet (attach follows PAR-04's CHECK-before-
        |      ATTACH discipline, per-month, during Step 3)
        v
Step 3: CREATE plat_event_idempotency, backfill it FIRST, before any events_part
        |   row work -- see PAR-05 body: "plat_event_idempotency SHALL be created and
        |      populated before the swap, so global idempotency_key uniqueness is
        |      never absent"
        v
Step 4: per-month backfill loop (DDL-04 discipline, reused verbatim)
        |   for each calendar month window in ascending created_at order:
        |     CREATE partition_YYYY_MM (PAR-04 CHECKs) + ATTACH to events_part
        |     ONE transaction per window:
        |       INSERT INTO events_part SELECT * FROM events
        |         WHERE created_at IN [window_start, window_end)
        |         ON CONFLICT (event_id, created_at) DO NOTHING
        |     interrupted/re-run window: ON CONFLICT absorbs duplicates, idempotent
        v
        (continued below)
```

```
Step 5: swap transaction (short, lock_timeout = 3s)
        |   BEGIN
        |     replay catch-up window: re-run Step 4's INSERT ... ON CONFLICT DO NOTHING
        |       for [last_backfilled_row.created_at, NOW()) -- closes the gap between
        |       the last completed backfill window and this instant
        |     ALTER TABLE events RENAME TO events_legacy
        |     ALTER TABLE events_part RENAME TO events
        |   COMMIT (or: lock_timeout fires -> ROLLBACK, both tables intact, retry
        |     at next maintenance window)
        v
Step 6: post-swap row-count reconciliation
        |   per-month COUNT(*) comparison: events_legacy vs. new events partitions
        |   match  -> conversion complete
        |   mismatch -> ConversionRowCountMismatch raised, inverse rename restores
        |     the original events (events RENAME TO events_part_failed,
        |     events_legacy RENAME TO events), operator/ORCH notified
        v
events_legacy retained read-only for one archive_after_months cycle (PAR-03's own
default, 13 months) -- then ATTACHed to events_archive (a catalog operation, not a
row copy), never emptied row by row (see Dependencies on PAR-03)
```

## Public interface

### Entry point and file placement

PAR-05 is **not** a single `zig build migrate` DDL file the way PAR-01 was — a migration file
is expected to run once, quickly, inside `Migrations.runForSchema()`'s per-file transaction
(`docs/guides/backend_developer_guide.md §4.4`). PAR-05's own AC text describes a *long-running,
resumable, interruptible* operation (backfill windows measured in calendar months, potentially
tens of millions of rows per PAR-03's own "40 million rows" retention example) that must **not**
run inside one migration-runner transaction — the swap step alone specifies `lock_timeout = 3s`,
which is meaningless if the whole conversion is one multi-hour transaction already holding
locks. This mirrors DDL-04's own constraint on its backfill phase ("The loop SHALL NOT run inside
an outer transaction").

Recommended shape (BACKEND-DEV to confirm exact wiring — flagged in Open questions §1):

```zig
pub const ConversionError = error{
    PoolExhausted,
    TransactionFailed,
    /// A calendar month between min(created_at) and the lead horizon has no
    /// planned target partition (PAR-05 AC2). Conversion does not start.
    PartitionRangeGap,
    /// Post-swap per-month row count differs between events_legacy and the
    /// new events partitions (PAR-05 AC5). Inverse rename already executed
    /// by the time this is returned to the caller.
    ConversionRowCountMismatch,
};

pub const ConversionConfig = struct {
    /// Same default horizon PAR-02 proactively maintains, so the converted
    /// events_part starts with the same future-partition supply a freshly
    /// PAR-01-built events table would have.
    lead_months: u8 = 2,
    /// Ceiling matching DDL-04's own bound; PAR-05's body does not specify
    /// a batch size directly (it batches by CALENDAR MONTH, not row count),
    /// so this only bounds the ON CONFLICT DO NOTHING INSERT...SELECT width
    /// within one already-month-scoped window on an unusually large month.
    backfill_batch_size: u32 = 5000,
};

pub const MonthRange = struct { start_us: i64, end_us: i64, suffix: [7]u8 };

pub const PartitionConverter = struct {
    pool: *db.Pool,
    config: ConversionConfig,

    pub fn init(pool: *db.Pool, config: ConversionConfig) PartitionConverter;
};
```

Steps 1–3 (validation, parent creation, idempotency backfill):

```zig
/// Step 1 (PAR-05 AC2). Read-only; issues no DDL. Returns the ordered
/// list of calendar months [min(created_at), max(created_at) +
/// lead_months] that Step 4 will need a target partition for.
pub fn validateCoverage(self: *PartitionConverter, allocator: std.mem.Allocator, conn: *db.Conn) ConversionError![]MonthRange;

/// Step 2. CREATE TABLE events_part (LIKE events INCLUDING DEFAULTS
/// INCLUDING IDENTITY) PARTITION BY RANGE (created_at). Idempotent:
/// a second call when events_part already exists and is unpartitioned-
/// by-nothing-else is a no-op (mirrors PAR-01 Migration 1's own
/// v_is_partitioned idempotency guard).
pub fn createParent(self: *PartitionConverter, allocator: std.mem.Allocator, conn: *db.Conn) ConversionError!void;

/// Step 3. CREATE plat_event_idempotency (same shape PAR-01 Migration 2
/// defines) and backfill it from every row currently in events, BEFORE
/// any events_part row work — PAR-05's own body makes this ordering an
/// explicit AC, not an implementation choice.
pub fn createAndBackfillIdempotency(self: *PartitionConverter, allocator: std.mem.Allocator, conn: *db.Conn) ConversionError!void;
```

Steps 4–6 (backfill loop, swap, reconciliation) — all methods on the same `PartitionConverter`:

```zig
/// Step 4 (PAR-05 AC1, AC3; DDL-04 discipline). Runs the per-month
/// backfill loop. Each month is ONE transaction: create+attach the
/// month's partition (PAR-04's CHECK-before-ATTACH via
/// partition_attach.attachPartitionTimed(), reused verbatim — see
/// Dependencies), then INSERT INTO events_part SELECT ... FROM events
/// WHERE created_at in that month's [start,end) ON CONFLICT (event_id,
/// created_at) DO NOTHING. Safe to call repeatedly after an
/// interruption: already-backfilled months are naturally re-scanned but
/// contribute zero new rows via the ON CONFLICT clause (PAR-05 AC3).
pub fn backfillAllMonths(self: *PartitionConverter, allocator: std.mem.Allocator, conn: *db.Conn, months: []const MonthRange) ConversionError!void;

/// Step 5 (PAR-05 AC4). The swap transaction: replays the catch-up
/// window since the last backfilled row, then issues the two RENAME
/// statements, all inside one transaction with lock_timeout = 3s. On a
/// lock-timeout ROLLBACK, both tables are left exactly as found —
/// caller should retry at the next maintenance window (PAR-02's daily
/// cadence is the natural retry point; see Open questions §1).
pub fn swap(self: *PartitionConverter, allocator: std.mem.Allocator, conn: *db.Conn) ConversionError!void;

/// Step 6 (PAR-05 AC5). Per-month COUNT(*) comparison between
/// events_legacy and the new events partitions. On mismatch, issues the
/// inverse rename (restoring the pre-swap names) before returning
/// ConversionRowCountMismatch — the caller never observes a
/// half-reconciled state where the swap "succeeded" but row counts were
/// never checked.
pub fn reconcileOrRollback(self: *PartitionConverter, allocator: std.mem.Allocator, conn: *db.Conn) ConversionError!void;
```

`MonthRange`/the month-arithmetic helpers (`monthRange`, `addMonthsUs`, `usToYearMonth`,
`yearMonthToUs`) are **not redefined** by this module — BACKEND-DEV reuses
`src/scheduler/partition_maintenance.zig`'s existing private helpers of the same names and
shapes, either by making them `pub` there (preferred: one definition, not a fork) or, if that
file's module boundary makes that awkward, by extracting them to a small shared module both
`partition_maintenance.zig` and this new `partition_conversion.zig` import. BACKEND-DEV's call —
flagged as Open questions §3, not decided here, since it is a code-organisation choice rather
than a schema/behaviour decision.

### `plat_event_idempotency` backfill (Step 3) — exact statement shape

Same table PAR-01's Migration 2 already defines (`idempotency_key TEXT PRIMARY KEY, event_id
UUID NOT NULL, created_at TIMESTAMPTZ NOT NULL`) — PAR-05 does not redefine its shape, only
specifies that in THIS conversion path it must be created and populated from the live `events`
table's full existing row set before the swap, rather than starting empty (as it does when
PAR-01's from-scratch migration runs against a genuinely empty `events`):

```sql
CREATE TABLE IF NOT EXISTS plat_event_idempotency (
    idempotency_key   TEXT            PRIMARY KEY,
    event_id          UUID            NOT NULL,
    created_at        TIMESTAMPTZ     NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_plat_event_idempotency_event
    ON plat_event_idempotency (event_id, created_at);

INSERT INTO plat_event_idempotency (idempotency_key, event_id, created_at)
SELECT idempotency_key, event_id, created_at FROM events
ON CONFLICT (idempotency_key) DO NOTHING;
```

Batched per DDL-04's discipline if `events` is large (the plain `INSERT ... SELECT` above is
the unbounded form; BACKEND-DEV should apply the same `ctid`-bounded batching DDL-04 specifies
for its own backfill phase if a single-statement backfill proves too slow against a real
`events` row count — this is an implementation-sizing decision, not a schema one, so left open
rather than dictated; see Open questions §4).

### Per-month backfill statement (Step 4) — exact statement shape

```sql
-- One transaction per month window. partition_YYYY_MM already CREATEd + ATTACHed
-- to events_part via partition_attach.attachPartitionTimed() before this INSERT.
INSERT INTO events_part
SELECT * FROM events
WHERE created_at >= $1 AND created_at < $2
ON CONFLICT (event_id, created_at) DO NOTHING;
```

`INSERT ... SELECT *` relies on `events_part` being column-identical to `events`
(`LIKE events INCLUDING DEFAULTS INCLUDING IDENTITY` in Step 2 guarantees this at creation time,
and no column is added to either table between Step 2 and Step 4 in this design).

### Swap statement (Step 5) — exact statement shape

```sql
BEGIN;
SET LOCAL lock_timeout = '3s';

-- Catch-up replay: same statement as the per-month backfill loop, scoped to
-- [last_backfilled_row.created_at, NOW()) rather than a calendar month.
INSERT INTO events_part
SELECT * FROM events
WHERE created_at >= $1 AND created_at < NOW()
ON CONFLICT (event_id, created_at) DO NOTHING;

ALTER TABLE events RENAME TO events_legacy;
ALTER TABLE events_part RENAME TO events;

COMMIT;
```

A `lock_timeout` expiry on either `ALTER TABLE ... RENAME` statement raises Postgres `55P03`
(`lock_not_available`), which aborts the transaction; nothing has been renamed and both tables
remain under their original names, exactly per PAR-05 AC4 ("a lock timeout rolls the transaction
back, leaves both tables intact and readable").

### Reconciliation and inverse-rename (Step 6) — exact statement shape

```sql
-- Per-month comparison. table_name values come from plat_partition_catalog
-- (both events_legacy's now-detached-named partitions and the new events'
-- attached partitions carry their own YYYY_MM-suffixed physical names).
SELECT
    lp.table_name AS legacy_partition,
    (SELECT count(*) FROM <legacy_partition>) AS legacy_count,
    np.table_name AS new_partition,
    (SELECT count(*) FROM <new_partition>) AS new_count
FROM plat_partition_catalog lp
JOIN plat_partition_catalog np ON <matching month>
WHERE lp.parent_table = 'events_legacy' AND np.parent_table = 'events';
```

The literal per-partition `COUNT(*)` calls above cannot be parameterised as a single query
(table names are identifiers, not values — the same constraint `partition_attach.zig`'s own doc
comment already documents for `ATTACH PARTITION`); BACKEND-DEV drives this as a loop over
`plat_partition_catalog` rows, executing one `SELECT count(*) FROM %I` per partition name via
`std.fmt.allocPrint` + `EXECUTE format(%I, ...)`-style quoting (matching the existing convention
in `partition_maintenance.zig`/`partition_retention.zig`), not a single dynamic SQL string built
from unvalidated input.

On mismatch:

```sql
BEGIN;
ALTER TABLE events RENAME TO events_part_failed;
ALTER TABLE events_legacy RENAME TO events;
COMMIT;
```

Returns `ConversionRowCountMismatch` naming the first mismatched month found. `events_part_failed`
is left in place (not dropped) for forensic inspection — this design does not specify automatic
cleanup of a failed conversion attempt; that is an operator/ORCH follow-up action, not part of
PAR-05's own acceptance criteria.

## Error taxonomy

| Error | Trigger | Surfaced as |
|---|---|---|
| `PartitionRangeGap` | Step 1 finds a calendar month between `min(created_at)` and the lead horizon with no planned target partition (PAR-05 AC2) | New `ConversionError` variant; conversion does not start, no DDL runs, no backfill runs |
| Postgres `55P03` (`lock_not_available`) during the Step 5 swap | `lock_timeout = 3s` expires on either `RENAME` statement (PAR-05 AC4) | Transaction rolls back automatically (Postgres aborts on lock-timeout); caller observes both tables intact under their original names; PAR-05's own text specifies "retried at the next maintenance window" — this design recommends wiring that retry into the SAME daily cadence PAR-02's `PartitionMaintenanceScheduler` already runs on, rather than a bespoke schedule (see Open questions §1) |
| `ConversionRowCountMismatch` | Step 6's per-month `COUNT(*)` comparison finds a mismatch between `events_legacy` and the corresponding new `events` partition (PAR-05 AC5) | New `ConversionError` variant; inverse rename already executed by the time this error is returned — caller does not need to perform its own rollback |
| Postgres `23505` (`unique_violation`) on `plat_event_idempotency_pkey` during Step 3's backfill | Should not occur in practice — the backfill INSERT itself uses `ON CONFLICT (idempotency_key) DO NOTHING`, so a genuine duplicate key silently contributes zero rows rather than raising; this row only documents that the ON CONFLICT clause is load-bearing here, same as PAR-01's own idempotency-insert pattern | Not surfaced as a distinct `ConversionError` — absorbed by the `DO NOTHING` clause per design |
| Step 4's per-month backfill transaction fails for a reason OTHER than the above (pool exhaustion, connection loss mid-window) | Any DB-layer failure during a single month's transaction | `TransactionFailed`; per PAR-05 AC3, the caller re-runs `backfillAllMonths()` — already-completed months' `ON CONFLICT DO NOTHING` makes re-running them a no-op, so retry is safe from any month boundary, not just the point of failure |

## Dependencies

- Depends on: PAR-01 (`plat_event_idempotency`'s shape, and `events`'s target partitioned shape
  this conversion produces — Step 2's `events_part` must end up column-and-constraint-identical
  to what `1147_par01_events_partitioning.sql` builds from scratch, so the two paths converge on
  the same steady state), PAR-04 (`src/db/partition_attach.zig`'s `attachPartitionTimed()` —
  every per-month partition this design creates in Step 4 MUST go through that function, not a
  raw `ALTER TABLE ... ATTACH PARTITION`, so the CHECK-before-attach discipline applies uniformly
  here too), DDL-04 (the batched, resumable, `ON CONFLICT`-idempotent backfill discipline this
  design's Step 3/Step 4 both reuse — this design does not re-derive that discipline, it applies
  it), PAR-03 (`events_legacy`'s eventual fate: retained read-only for one `archive_after_months`
  cycle, then ATTACHed to `events_archive` — this design does not implement that attach step,
  only states the retention contract PAR-05's own body specifies; PAR-03's `PartitionRetention`
  module is the natural owner of actually performing it once `events_legacy` ages past the
  threshold, flagged in Open questions §5 since PAR-03's existing code does not yet know about
  `events_legacy` as a distinct case from an ordinary aged-out `events_YYYY_MM` partition).
- Must NOT depend on: PAR-06 (time-bounded reconstruction queries — an independent, later
  requirement in this same batch; this conversion's own row movement does not require PAR-06's
  bounded-query convention to function, though PAR-06's bound predicate does benefit from
  `events_part`/the renamed `events` already being partitioned once this conversion completes).
  Does NOT depend on ISS-0670/GH-711 (the `EXECUTION_PARTITION_CREATED`/`EXECUTION_PARTITION_DETACHED`/
  `EXECUTION_PARTITION_DROPPED` platform-event emission gap tracked against PAR-02 AC5/PAR-03
  AC6) — confirmed by reading PAR-05's body and `See:` list in full: it names PAR-01, PAR-03,
  PAR-04, DDL-04 only, and none of its five acceptance criteria mention appending any
  `EXECUTION_*` event. This design's Step 4 (partition creation) and Step 5/Step 6 (swap/detach-
  equivalent bookkeeping) intentionally do not append `EXECUTION_PARTITION_CREATED` or any
  sibling event — doing so would require exactly the missing platform-event-append convention
  ISS-0670/GH-711 identifies as absent, and PAR-05's own AC text does not require it. If a later
  requirement wants conversion-time partitions to also emit `EXECUTION_PARTITION_CREATED`, that
  is new scope requiring its own AC and depends on ISS-0670/GH-711's resolution — not assumed
  here.

## Open questions

1. **Conversion entry point — CLI tool, one-shot migration, or ORCH-triggered operational
   procedure?** PAR-05's body describes a real operational event ("the one-time conversion of an
   EXISTING `events` table") rather than a routine `zig build migrate` step every fresh schema
   runs through. This design defines the `PartitionConverter` API (Public interface) but does not
   pick how an operator/ORCH actually invokes it — options include a new `zig build convert-
   partitions` build step, a one-off migration file that calls into this module conditionally
   (skipping cleanly if `events` is already partitioned, mirroring PAR-01's own
   `v_is_partitioned` guard), or a standalone CLI binary under `tools/`. Needs BACKEND-DEV/ORCH
   judgment — this is implementation wiring, not a schema/behaviour decision, so intentionally
   left open rather than dictated. The retry-at-next-maintenance-window language in PAR-05 AC4
   suggests hooking `swap()`'s retry into `PartitionMaintenanceScheduler`'s existing daily loop
   (PAR-02) is the most consistent choice with this codebase's existing conventions, but is not
   mandated here.
2. **Test coverage given the Scoping note's finding that PAR-05 is unreachable via a fresh
   `bpm_test` provisioning.** TEST-DESIGNER will need a fixture that first builds `events` in its
   PRE-PAR-01 unpartitioned shape (the exact DDL `001_event_store.sql`/`003_event_archive.sql`
   originally used), populates it with rows spanning multiple calendar months, and only THEN
   exercises this module's conversion path — deliberately bypassing `1147_par01_events_
   partitioning.sql`'s already-partitioned target for that one test's setup. This is unusual
   relative to every other test in this codebase (which all build on top of the full, current
   migration set via `TestHarness.init()`) and needs explicit acknowledgement from TEST-DESIGNER/
   TEST-DESIGN-VALIDATOR that a bespoke non-`TestHarness` fixture is warranted here, not a gap.
3. **Where `MonthRange`/month-arithmetic helpers should live.** Recommended in Public interface
   (make `partition_maintenance.zig`'s existing helpers `pub`, or extract to a shared module) but
   left to BACKEND-DEV as a code-organisation call, not a schema/behaviour decision.
4. **`plat_event_idempotency` backfill batching threshold.** Step 3 shows the unbounded
   single-statement form; DDL-04's `ctid`-bounded batching is available as a documented fallback
   if unbounded backfill proves too slow against a real `events` row count, but this design does
   not mandate the switchover point (row count, elapsed time) — an implementation-sizing decision
   BACKEND-DEV/RELEASE-VALIDATOR can make from NFR benchmark evidence rather than a priori here.
5. **`events_legacy`'s eventual ATTACH into `events_archive` — whose code path owns it?**
   PAR-05's body states the retention contract (`archive_after_months` cycle, then ATTACHed, never
   emptied row by row) but `src/scheduler/partition_retention.zig`'s existing
   `runArchivalAging()` only evaluates rows from `plat_partition_catalog WHERE parent_table =
   'events'` — it has no awareness of a table literally named `events_legacy` as a distinct
   parent needing the same aging treatment. This is a genuine integration gap between this design
   and PAR-03's existing implementation, not resolved here: either `events_legacy`'s constituent
   month-partitions need to be registered into `plat_partition_catalog` under `parent_table =
   'events_legacy'` so `runArchivalAging()`'s existing query naturally picks them up once
   `PartitionRetention` is extended to also scan that parent, or a new, PAR-05-specific aging path
   is needed. Flagged for REQ-ANALYST/CODE-DESIGNER follow-up when PAR-05 is actually
   implemented — not blocking THIS design (which only needs to specify the swap/conversion itself,
   per PAR-05's own AC text), but the retention bullet in PAR-05's body is not fully actionable by
   BACKEND-DEV from PAR-03's code as it exists today without this gap being closed first.
