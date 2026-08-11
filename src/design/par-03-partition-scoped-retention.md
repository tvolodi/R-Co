# Module: par-03-partition-scoped-retention

**Requirement ID:** PAR-03
**Run ID:** WF02-batch-3-20260811 (Stage 16)
**Covers:** PAR-03
**Extends:** ADP-11 (gives the deletion prohibition a physical retention mechanism — already
released, `src/event_store/store.zig`'s `isProtectedEventFamily`/`ProtectedFamilyHardDeleteForbidden`)
**See also (not implemented here):** PAR-01 (schema shape — separate design, already produced),
PAR-02 (the daily job this module's DETACH/ATTACH/DROP logic runs alongside — separate design,
already produced), PAR-04 (the `AttachScanRequired` pre-attach check this module's archival
attach MUST call — separate design, already produced), ES-07 (the row-level retention-policy
engine this module's partition-level mechanism supersedes for the protected families — see Open
questions §1 for the unresolved overlap `par-01`'s design already flagged)

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** PAR-03's own acceptance criteria need one new column
   (`event_type_registry.retention_class`) and reuse `plat_partition_catalog` (PAR-02's table,
   this same batch) for `ORPHAN_PARTITION` state tracking — a small, standard `ALTER TABLE ADD
   COLUMN` fits the Type C template cleanly (see Public interface, Migration 1) and is produced
   as such, consistent with the handoff's own expectation ("Type E ... likely extends whatever
   module PAR-02's maintenance job lives in, or a sibling module").
2. **Type A / Type D / Type B?** No HTTP route, no React Flow node, no admin page.
3. **Type E — yes**, for the DETACH/ATTACH/DROP retention logic itself: multi-step partition
   lifecycle orchestration with a guard-then-act sequence (the ADP-11 ephemeral-drop guard) and
   failure-recovery state (`ORPHAN_PARTITION`) — squarely cross-cutting business logic, not a
   template-shaped CRUD/list/migration/node piece.

## Scoping note — relationship to PAR-02's job

PAR-03's DETACH/ATTACH/DROP logic runs as **part of the same daily `plat_partition_maintenance`
job** PAR-02 defines (`docs/processes/system/event-log-partitioning.md`'s Steps 8-12 list
partition creation, then archival aging, then ephemeral dropping, all under one "Scheduler" actor
and one daily cadence — there is no separate cron entry for retention). This design adds a
sibling module, `src/scheduler/partition_retention.zig`, that PAR-02's
`PartitionMaintenanceScheduler.runMaintenanceCycle()` calls after its own creation loop
completes, rather than folding retention logic directly into PAR-02's file — keeping the
"proactive creation" and "aging out the past" concerns in separately testable units, matching how
`src/scheduler/scheduler.zig` and `src/scheduler/recurrence.zig` are already split by concern in
this codebase (poll loop vs. recurrence-interval computation) rather than one large file.

## Module purpose

`src/scheduler/partition_retention.zig` (new file) implements two related operations, both
partition-catalog-only (no row movement):

1. **Archival aging**: for each `events` partition older than `archive_after_months` (default
   13), `DETACH PARTITION ... CONCURRENTLY` from `events`, then `ATTACH PARTITION` the same
   physical relation to `events_archive` (via PAR-04's `attachPartitionTimed()`). A failed attach
   after a successful detach leaves the partition standalone, recorded `ORPHAN_PARTITION` in
   `plat_partition_catalog`, remaining queryable and retried on the next cycle.
2. **Ephemeral dropping**: for each `events_ephemeral` partition older than
   `ephemeral_drop_after_months` (default 3), run the ADP-11 protected-row guard query; a
   zero count permits `DROP TABLE`, a non-zero count raises `Adp11GuardTripped` as a BLOCKER and
   leaves the partition attached.

Both operations append their own audit event (`EXECUTION_PARTITION_DETACHED` /
`EXECUTION_PARTITION_DROPPED`) to the event log on success.

This design also adds `retention_class` to `event_type_registry` (Migration 1) so that
`RetentionClassForbidden` (PAR-03 AC1) has a concrete column to validate against — the process
document's Inputs table names `retention_class` as `retain_forever | archive_queryable | delete`
per event type, which does not exist as a column anywhere in the current schema (confirmed by
grep across `migrations/`).

## Data flow diagram

```
PAR-02's runMaintenanceCycle(), after its own creation loop completes
        |
        v
PartitionRetention.runArchivalAging(allocator, conn)
        |
        |-- SELECT table_name, range_end FROM plat_partition_catalog
        |     WHERE parent_table = 'events' AND state = 'ATTACHED'
        |       AND range_end < now() - archive_after_months
        v
   for each aged partition:
        |-- ALTER TABLE events DETACH PARTITION <name> CONCURRENTLY
        |         | success                        | failure
        |         v                                v
        |   UPDATE plat_partition_catalog       leave state=ATTACHED,
        |     SET state='DETACHED'               log error, retry next cycle
        |         |
        |         v
        |   PAR-04's attachPartitionTimed(conn, "events_archive", <name>, range)
        |         |
        |         +-- .ok --> UPDATE state='ATTACHED', parent_table='events_archive';
        |         |            append EXECUTION_PARTITION_DETACHED
        |         +-- .attach_scan_required OR any DB error -->
        |                UPDATE plat_partition_catalog SET state='ORPHAN_PARTITION'
        |                (partition remains standalone, still queryable directly by name;
        |                 retried next cycle per PAR-03 AC5)
```

```
PartitionRetention.runEphemeralDrop(allocator, conn), continued from the same cycle:
        |
        |-- SELECT table_name FROM plat_partition_catalog
        |     WHERE parent_table = 'events_ephemeral' AND state = 'ATTACHED'
        |       AND range_end < now() - ephemeral_drop_after_months
        v
   for each aged ephemeral partition:
        |-- SELECT count(*) FROM <name> WHERE split_part(event_type, '_', 1)
        |       IN ('INSTANCE', 'TASK', 'GATEWAY', 'EXECUTION')
        |         | count = 0                      | count > 0
        |         v                                v
        |   DROP TABLE <name>;                  raise Adp11GuardTripped (BLOCKER);
        |   UPDATE plat_partition_catalog        partition stays attached;
        |     SET state='DROPPED';               escalate to Platform Admin;
        |   append EXECUTION_PARTITION_DROPPED   no drop occurs
```

## Public interface

### Migration 1 (Type C for the ALTER + hand-written for `events_ephemeral`, one file:
`migrations/1149_par03_retention_class.sql`, generated from
`templates/specs/par-03-retention-class.migration.yaml`)

The YAML's `tables:` block covers ONLY the codegen-clean `event_type_registry` ALTER
(`retention_class` column + `chk_retention_class` CHECK). Confirmed by actually running
`python tools/lint_design_artefact.py` against a two-`pk:true`-column draft of this file: the
Y125 rule rejects it outright ("2 pk:true columns (max 1)"), and `tools/codegen_migration.py` has
no `PARTITION BY` support at all (same gap PAR-01's design already hit for
`events`/`events_archive`) — so `events_ephemeral` cannot go through codegen even as a CUSTOM
override. It is hand-written in the SAME generated migration file, following PAR-01's Migration 1
guarded-rebuild + Migration 4 seed-loop pattern exactly:

```sql
CREATE TABLE events_ephemeral (
    event_id          UUID            NOT NULL,
    instance_id       UUID            NOT NULL,
    event_type        TEXT            NOT NULL,
    payload           JSONB           NOT NULL DEFAULT '{}',
    actor_id          UUID            NOT NULL,
    created_at        TIMESTAMPTZ     NOT NULL,
    sequence_number   BIGINT          NOT NULL,
    idempotency_key   TEXT            NOT NULL,
    metadata          JSONB           NOT NULL DEFAULT '{}',
    global_seq        BIGINT          NOT NULL,
    tenant_id         UUID            NOT NULL,
    PRIMARY KEY (event_id, created_at)
) PARTITION BY RANGE (created_at);

CREATE INDEX idx_events_ephemeral_instance ON events_ephemeral (instance_id, sequence_number);
CREATE INDEX idx_events_ephemeral_type ON events_ephemeral (event_type);
```

Initial partition seed: same 3-month (current + `lead_months`) loop as PAR-01's Migration 4,
retargeted at `events_ephemeral`, each partition carrying both `CHECK (tenant_id IS NOT NULL)`
and the matching range CHECK before being attached — see
`src/design/par-01-monthly-range-partitioning.md`'s Migration 4 for the exact `DO $$ ... EXECUTE
format(...)` shape this reuses verbatim with the parent table name substituted.

Both statements are guarded by the same `v_is_partitioned` idempotency check PAR-01's Migration 1
uses (re-running this migration against a schema where it already succeeded is a no-op), applied
here to `events_ephemeral` specifically rather than duplicated as a third independent guard.

### Retention logic (Type E, `src/scheduler/partition_retention.zig`)

```zig
const std = @import("std");
const db = @import("pool");
const partition_attach = @import("../db/partition_attach.zig"); // PAR-04

pub const RetentionConfig = struct {
    archive_after_months: u8 = 13,
    ephemeral_drop_after_months: u8 = 3,
};

pub const PartitionState = enum { attached, detached, orphan_partition, dropped };

pub const ArchivalAgingResult = struct {
    detached_and_reattached: u32,
    orphaned: u32,
};

pub const EphemeralDropResult = struct {
    dropped: u32,
    guard_tripped: u32,
};
```

```zig
pub const RetentionError = error{
    PoolExhausted,
    TransactionFailed,
    /// The pre-drop guard found protected-family rows in an events_ephemeral
    /// partition (PAR-03 AC4) — the partition stays attached, no DROP runs.
    /// A typed error, not silently retried: an event ever landing in
    /// events_ephemeral with a protected type prefix indicates a routing
    /// bug elsewhere (ADP-11 is supposed to reject `delete` retention_class
    /// configuration for these types at configuration time), not a
    /// transient condition — see PAR-03's body and Error taxonomy.
    Adp11GuardTripped,
};

pub const PartitionRetention = struct {
    pool: *db.Pool,
    config: RetentionConfig,

    pub fn init(pool: *db.Pool, config: RetentionConfig) PartitionRetention;

    /// DETACH-then-ATTACH every events partition older than
    /// archive_after_months. Calls PAR-04's attachPartitionTimed() for the
    /// re-attach step. A failed re-attach after a successful detach is
    /// recorded ORPHAN_PARTITION, not retried within this same call.
    pub fn runArchivalAging(self: *PartitionRetention, allocator: std.mem.Allocator, conn: *db.Conn) RetentionError!ArchivalAgingResult;

    /// Runs the ADP-11 pre-drop guard and DROP TABLE for every
    /// events_ephemeral partition older than ephemeral_drop_after_months.
    /// Returns Adp11GuardTripped on the FIRST guard trip encountered (does
    /// not continue past a blocked drop to try later partitions in the same
    /// call — see Error taxonomy for why "stop and escalate" beats "skip
    /// and continue" here).
    pub fn runEphemeralDrop(self: *PartitionRetention, allocator: std.mem.Allocator, conn: *db.Conn) RetentionError!EphemeralDropResult;

    /// Retries any partition currently in ORPHAN_PARTITION state — called
    /// at the START of runArchivalAging() each cycle, before evaluating
    /// newly-aged partitions, per PAR-03 AC5 ("retried on the next
    /// maintenance run").
    fn retryOrphanedAttaches(self: *PartitionRetention, allocator: std.mem.Allocator, conn: *db.Conn) RetentionError!void;
};
```

## Error taxonomy

| Error | Trigger | Surfaced as |
|---|---|---|
| `RetentionError.Adp11GuardTripped` | Ephemeral-drop guard finds a protected-family row in an `events_ephemeral` partition (PAR-03 AC4) | Returned to the caller (PAR-02's cycle); `runEphemeralDrop()` stops at the FIRST tripped guard rather than silently skipping that partition and continuing to the next — a tripped guard means a protected-family event was routed into `events_ephemeral` at all, which per ADP-11/PAR-03's own body should be structurally impossible (retention_class `delete` is refused for protected types at configuration time); continuing past it risks masking the same routing bug across multiple partitions in one cycle. Caller escalates as BLOCKER to Platform Admin (process document's SLA table) |
| `ORPHAN_PARTITION` (not a Zig error — a `plat_partition_catalog.state` value) | `DETACH PARTITION` commits but the subsequent `ATTACH PARTITION` to `events_archive` fails (PAR-03 AC5) | Not surfaced as a thrown error to the caller — `runArchivalAging()` catches the attach failure internally, records the state transition, and continues to the next aged partition (unlike the ephemeral-drop guard trip, an orphaned partition is an expected, self-healing transient state, not evidence of a routing bug) |
| `RetentionError.PoolExhausted` / `TransactionFailed` | DB connectivity issue during either operation | Propagated to caller; PAR-02's cycle treats identically to its own DB errors — the whole maintenance cycle for that day is considered incomplete and retried next boundary, without marking `plat_partition_maintenance_run_log` as fully successful for partitions not yet processed (see Open questions §3 for exactly what "partially completed cycle" means for the run-log idempotency gate) |
| `AttachScanRequired` (from PAR-04, surfaced as the "any DB error" branch in Data flow diagram) | The re-attach step's candidate partition (the just-detached, pre-existing relation) is missing a required CHECK | Should not occur in practice — the partition was originally created with both CHECKs by PAR-01's seed or PAR-02's creation loop, and DETACH/ATTACH does not alter a table's own constraints. If it does occur, treated as an `ORPHAN_PARTITION` transition exactly like any other re-attach failure, not a distinct error path — a genuinely missing CHECK on an already-attached partition would be a pre-existing data-integrity problem this module cannot repair mid-cycle |

## Dependencies

- Depends on: PAR-01's schema (`events`/`events_archive`/`plat_event_idempotency`), PAR-02's
  `plat_partition_catalog` (state tracking) and `runMaintenanceCycle()` (the caller), PAR-04's
  `attachPartitionTimed()` (the re-attach step), ADP-11's already-released
  `isProtectedEventFamily()` logic in `src/event_store/store.zig` (this design's ephemeral-drop
  guard reimplements the SAME family-prefix check as a SQL predicate rather than calling the Zig
  function, since the guard runs as a single `SELECT count(*)` against the partition, not a
  per-row Zig-side check — see Open questions §4 for why this duplication is accepted rather than
  factored out).
- Must NOT depend on: `Store.archive()` (`src/event_store/store.zig`) — see PAR-01's Open
  questions §7 for why that function's row-level `DELETE FROM events` pattern is incompatible
  with this design's "no `DELETE` against `events`/`events_archive`" rule; this module does not
  call it and does not attempt to reconcile the two, leaving that reconciliation to whichever
  later workflow retires or rewrites `archive()`.

## Open questions

1. **`Store.archive()` overlap — still unresolved from PAR-01's design.** PAR-01's design (this
   same batch) already flags that `Store.archive()`'s row-level `DELETE FROM events`/`DELETE FROM
   events_archive`-adjacent statements become forbidden the moment PAR-03 ships (PAR-03's body:
   "No `DELETE` statement SHALL run against `events` or `events_archive` at any point"). This
   design does not resolve that overlap either — it only implements the NEW partition-scoped
   mechanism PAR-03 requires, leaving `archive()` itself untouched and increasingly stale.
   Restated here because PAR-03 is the requirement whose acceptance criteria `archive()` would
   actually violate at runtime if both code paths were live simultaneously (e.g. an operator with
   an old `keep_days` policy still configured would trigger `archive()`'s `DELETE FROM events`
   against a partitioned table, which works mechanically — Postgres routes a partition-targeting
   DELETE through the parent fine — but violates PAR-03's stated invariant). Recommend ORCH
   schedule a follow-up requirement or WF-03 issue to retire/gate `archive()` before PAR-03's
   design reaches implementation, not as part of this batch's own scope.
2. **RESOLVED during this design: `events_ephemeral`'s composite PK under
   `tools/codegen_migration.py`.** Confirmed by actually running
   `python tools/lint_design_artefact.py` against a two-`pk:true`-column draft — Y125 rejects it
   ("2 pk:true columns (max 1)"). `templates/specs/par-03-retention-class.migration.yaml` was
   corrected to cover only the codegen-clean `event_type_registry` ALTER; `events_ephemeral` is
   hand-written in the same generated migration file (see Public interface, Migration 1) rather
   than forced through codegen. No longer open — recorded here for traceability since an earlier
   draft of this design assumed the opposite.
3. **Partial-cycle completion semantics for the run-log idempotency gate.** PAR-02's design
   marks `plat_partition_maintenance_run_log` "ran" as soon as the day's row is claimed (before
   PAR-03's archival/ephemeral steps even begin) — so a cycle that successfully creates future
   partitions (PAR-02's own work) but then fails partway through PAR-03's archival aging (e.g.
   pool exhaustion mid-loop) would NOT be re-attempted until the next day, per PAR-02's "already
   ran today" no-op gate, even though several months' worth of aging/dropping never happened.
   This is a genuine gap between PAR-02's single-flag-per-day idempotency model and PAR-03's
   per-partition retry model (`ORPHAN_PARTITION` retries happen WITHIN a day's cycle, but a cycle
   that never got that far waits a full day). Recommend PAR-02's `plat_partition_maintenance_run_log`
   track completion more granularly (e.g. separate `creation_completed_at`/`retention_completed_at`
   timestamps) if BACKEND-DEV finds this gap unacceptable in practice — left as an open question
   rather than silently resolved, since it requires revisiting PAR-02's already-produced schema.
4. **ADP-11 family-prefix check duplicated in SQL vs. reused from `store.zig`.** The ephemeral-drop
   guard's `split_part(event_type, '_', 1) IN ('INSTANCE', 'TASK', 'GATEWAY', 'EXECUTION')`
   predicate (PAR-03's own body, verbatim) is a second implementation of the same rule
   `isProtectedEventFamily()` in `src/event_store/store.zig` already encodes in Zig
   (`std.mem.startsWith(u8, event_type, "INSTANCE_")`, etc.). PAR-03's body mandates the SQL form
   exactly (it is a whole-partition aggregate guard, which cannot be expressed as a per-row Zig
   call without reading every row first — defeating the point of a cheap pre-drop guard), so this
   duplication is accepted as unavoidable rather than a reuse failure. Flagged only so a future
   change to the protected-family prefix list (currently hardcoded in BOTH places) is not missed
   in one of the two call sites — a candidate for a follow-up "keep both lists in sync" lint,
   out of scope for this design.
