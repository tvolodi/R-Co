# Module: par-02-partition-maintenance-job

**Requirement ID:** PAR-02
**Run ID:** WF02-batch-3-20260811 (Stage 16)
**Covers:** PAR-02
**Extends:** PAR-01 (the partitioned tables this job maintains), SCH-05 (missed-run recovery
path this job's "recovered on the SCH-05 path" AC reuses)
**See also (not implemented here):** PAR-01 (schema shape — separate design, already covers the
initial 3-month partition seed), PAR-03 (retention DETACH/ATTACH — separate design, likely a
sibling module in the same directory, see Dependencies), PAR-04 (the `AttachScanRequired`
pre-attach check this job's creation loop MUST call — separate design, already produced in this
batch)

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** No new table is required by PAR-02's own acceptance criteria in isolation — the
   partitions it creates are `events`/`events_archive` partitions (PAR-01's schema, not a new
   table shape), and its own bookkeeping needs (see below) reuse `plat_partition_catalog`, which
   this design treats as PAR-02's own small schema addition (see "Small Type C piece" below) —
   consistent with the handoff's own expectation ("Type E ... plus possibly a small Type C piece
   if a job-tracking table is needed").
2. **Type A / Type D / Type B?** No HTTP route, no React Flow node, no admin page.
3. **Type E — yes**, for the job logic itself: a background daily-cadence maintenance loop is
   cross-cutting scheduling logic, the same class of work `docs/agents/AGENT_SYSTEM.md`'s Type E
   examples (engine kernel, cross-module orchestration sagas) describe, and squarely the kind of
   logic `templates/lego-catalog.md` reserves for Type E ("Anything performance-sensitive" is
   listed there too — an under-provisioned partition horizon is a production incident, not a
   cosmetic bug).

### Small Type C piece: `plat_partition_catalog`

`docs/processes/system/event-log-partitioning.md`'s Outputs table names `plat_partition_catalog`
("One row per partition: table, range bounds, attached parent, row count, state") as an output of
this whole process. PAR-02's own acceptance criteria need a durable place to record: (a) when the
job last ran (for the "runs twice in one day is a no-op" idempotency AC), (b) the current count of
attached future partitions (for the WARN-at-1/BLOCKER-at-0 lead-time AC), and (c) partition state
transitions (`ORPHAN_PARTITION` is PAR-03's concern, but the same table is the natural home for
it — see PAR-03's design). This table is simple enough (flat columns, no partitioning of its own,
one straightforward unique constraint) to go through the standard Type C migration template
rather than needing prose — see Public interface, Migration 1.

## Module purpose

`src/scheduler/partition_maintenance.zig` (new file) implements `plat_partition_maintenance`: a
daily-cadence background job that (1) ensures `lead_months` future monthly partitions are
attached to `events` (and, per PAR-01's design extending the same discipline to
`events_archive`, confirms `events_archive`'s own near-term partition coverage is intact — though
PAR-02's own body is scoped to `events`; `events_archive`'s ongoing partition supply is populated
by PAR-03's DETACH/ATTACH cycle, not by this job creating NEW empty `events_archive` partitions
beyond PAR-01's initial seed — see Open questions §1), (2) is idempotent (a second run within the
same day is a safe no-op), (3) raises WARN/BLOCKER severity events as the lead-time buffer
shrinks, and (4) recovers a missed run via the same "fire all overdue work on restart" pattern
SCH-05 already established for timers.

This design does NOT implement PAR-03's DETACH/archival logic or PAR-04's CHECK-verification
predicate — both are separate designs in this same batch. This job's creation loop CALLS PAR-04's
`attachPartitionTimed()` (see `src/design/par-04-attach-scan-required-check.md`) before every
`ATTACH PARTITION` it issues.

## Data flow diagram

```
Platform startup (main.zig bootstrap, analogous to how scheduler_poller is wired — see
Dependencies for the one thing this design does NOT resolve about that wiring)
        |
        v
PartitionMaintenanceScheduler.init(pool, config)
        |
        v
runDailyLoop() [background thread, analogous to Scheduler.pollDueTimers's poll loop shape]
        |
        |<--------------------------------------------------------------+
        |                                                                |
        v                                                                |
computeNextRunDelay(now, last_run_date)                                  |
        |  (sleeps until next 00:15 UTC boundary, OR immediately         |
        |   if last_run_date is not today — SCH-05-style catch-up)       |
        v                                                                |
runMaintenanceCycle(allocator)                                           |
        |                                                                |
        |-- INSERT ... ON CONFLICT (run_date) DO NOTHING (idempotency)   |
        |-- already ran today (no row returned)? --yes--> no-op, return -+
        |         | no
        v
(continued below — same call, split only for the 40-line design-sketch cap)
```

```
runMaintenanceCycle(allocator), continued:
        |
        |-- for month in [current_month .. current_month + lead_months]:
        |     for parent in ["events", "events_ephemeral"]:      [REWORK 2 — see below]
        |       partition already exists AND attached? --yes--> skip
        |         | no
        |         v
        |     CREATE TABLE <parent>_YYYY_MM (LIKE <parent> INCLUDING
        |       DEFAULTS, CHECK (tenant_id IS NOT NULL),
        |       CHECK (created_at range))
        |         |
        |         v
        |     PAR-04's attachPartitionTimed(conn, <parent>, "<parent>_YYYY_MM", range)
        |         |
        |         +-- .ok --> ATTACH PARTITION issued; append
        |         |            EXECUTION_PARTITION_CREATED
        |         +-- .attach_scan_required --> escalate, do NOT attach
        |
        |-- count attached future "events" partitions (events_ephemeral counted
        |     separately, see body-sketch step 3 below — lead-time severity is
        |     about writer availability for the MAIN log, not the ephemeral one)
        |     == 0 --> raise BLOCKER (before any append can fail)
        |     == 1 --> raise WARN
        |     >= 2 --> healthy, no alert
        |
        |-- UPDATE plat_partition_maintenance_run_log SET future_partition_count
        |
        v
   sleep until next 00:15 UTC boundary; loop back to runDailyLoop's top
```

**REWORK 2 addition — `events_ephemeral` joins the creation loop.** Per
`src/design/par-03-partition-scoped-retention.md`'s "Interaction with the partition structure"
section (added when PAR-03's design was extended to implement the append-time retention-class
routing `docs/processes/system/event-log-partitioning.md` Step 7 requires): a `delete`-class
event type now routes its appends to `events_ephemeral` instead of `events` at write time, so
`events_ephemeral` needs `lead_months` future partitions attached ahead of need for the exact same
reason `events` does — an append landing in a month with no attached `events_ephemeral_YYYY_MM`
partition fails `PartitionMissingForWrite` exactly as an under-provisioned `events` would. This
loop now iterates BOTH `events` and `events_ephemeral` as `parent` (shown above), not `events`
alone — `events_archive` remains excluded from this proactive-creation loop as before (see Open
questions §1: its ongoing partition supply comes from PAR-03's DETACH/ATTACH cycle, not from this
job creating new empty `events_archive` partitions past PAR-01's initial seed; that reasoning is
unaffected by this addition since `events_ephemeral` is a *write target*, like `events`, not an
*archival destination*, like `events_archive`).

## Public interface

### Migration 1 (Type C, `templates/specs/par-02-partition-catalog.migration.yaml`)

```yaml
schema_version: 1
migration_number: 1148   # next free after PAR-01's 1147
name: par02_partition_catalog
requirement_ids: [PAR-02]
purpose: |
  Tracks the maintenance job's last-run date (idempotency AC) and one row per
  known partition (table name, range bounds, attached parent, state) so the
  daily job and PAR-03's archival cycle share a single source of truth for
  partition state, per docs/processes/system/event-log-partitioning.md's
  plat_partition_catalog output.
tables:
  - mode: create
    name: plat_partition_catalog
    columns:
      - { name: id,              type: uuid,          pk: true, default: gen_random_uuid() }
      - { name: table_name,      type: text,          not_null: true }
      - { name: parent_table,    type: text,           not_null: true }
      - { name: range_start,     type: "timestamptz",  not_null: true }
      - { name: range_end,       type: "timestamptz",  not_null: true }
      - { name: state,           type: text,           not_null: true, default: "'ATTACHED'", check: "state IN ('ATTACHED', 'DETACHED', 'ORPHAN_PARTITION', 'DROPPED')" }
      - { name: created_at,      type: "timestamptz",  not_null: true, default: now() }
      - { name: updated_at,      type: "timestamptz",  not_null: true, default: now() }
    constraints:
      - { kind: unique, name: plat_partition_catalog_table_uq, columns: [table_name] }
    indexes:
      - { name: idx_plat_partition_catalog_parent_state, columns: [parent_table, state] }
  - mode: create
    name: plat_partition_maintenance_run_log
    columns:
      - { name: id,              type: uuid,          pk: true, default: gen_random_uuid() }
      - { name: run_date,        type: date,           not_null: true }
      - { name: ran_at,          type: "timestamptz",  not_null: true, default: now() }
      - { name: future_partition_count, type: integer, not_null: true }
    constraints:
      - { kind: unique, name: plat_partition_maintenance_run_log_date_uq, columns: [run_date] }
```

`plat_partition_maintenance_run_log`'s `UNIQUE (run_date)` is what makes the "runs twice within
the same day is a no-op" acceptance criterion (PAR-02 AC2) enforceable at the database level: the
job's first statement in `runMaintenanceCycle()` is `INSERT INTO
plat_partition_maintenance_run_log (run_date, future_partition_count) VALUES (CURRENT_DATE, 0)
ON CONFLICT (run_date) DO NOTHING RETURNING id`; an empty `RETURNING` means today's run already
happened, and the function returns immediately without creating anything or raising an error
(PAR-02 AC2: "creates nothing, raises no error, and leaves the partition set unchanged").

Both tables are `plat_`-prefixed per the DDL-05 reserved-namespace convention (`src/platform/ddl_namespace.zig`)
— platform-owned, per-tenant-schema bookkeeping tables, consistent with `plat_event_idempotency`
(PAR-01) and the existing `plat_migration_plan`/`plat_outbox`-style naming this codebase already
uses elsewhere (see DDL-01's own test fixtures referencing `plat_outbox`, `plat_hijacked` as
examples of the convention).

### Job logic (Type E, `src/scheduler/partition_maintenance.zig`)

```zig
const std = @import("std");
const db = @import("pool");
const partition_attach = @import("../db/partition_attach.zig"); // PAR-04

pub const PartitionMaintenanceConfig = struct {
    lead_months: u8 = 2,
    run_hour_utc: u8 = 0,
    run_minute_utc: u8 = 15,
};

pub const MaintenanceSeverity = enum { healthy, warn, blocker };

pub const MaintenanceCycleResult = struct {
    ran: bool,               // false if today's run already happened (idempotent no-op)
    partitions_created: u32,
    future_partition_count: u32,
    severity: MaintenanceSeverity,
};

pub const PartitionMaintenanceError = error{
    PoolExhausted,
    TransactionFailed,
    /// PAR-04's attachPartitionTimed() returned attach_scan_required for a
    /// partition this job itself just created — should not occur in
    /// practice (this job always creates both required CHECKs before
    /// attaching, see Data flow diagram), but surfaced as a typed error
    /// rather than silently retried, per docs/anti-patterns.md's stub/
    /// silent-success entry family.
    UnexpectedAttachScanRequired,
};
```

The scheduler struct itself (split into a second block, same file, continued):

```zig
pub const PartitionMaintenanceScheduler = struct {
    pool: *db.Pool,
    config: PartitionMaintenanceConfig,

    pub fn init(pool: *db.Pool, config: PartitionMaintenanceConfig) PartitionMaintenanceScheduler;

    /// Background loop entry point (mirrors Scheduler.pollDueTimers's shape
    /// in src/scheduler/scheduler.zig, adapted from a short-interval poll to
    /// a daily-cadence sleep-until-boundary loop — see Dependencies for why
    /// this is a NEW pattern in this codebase, not a reuse of SCH-02's
    /// exact loop).
    pub fn runDailyLoop(self: *PartitionMaintenanceScheduler, allocator: std.mem.Allocator) noreturn;

    /// Computes milliseconds to sleep until the next scheduled run: either
    /// the next 00:15 UTC boundary, or 0 (run immediately) if today's run
    /// has not yet happened and the current time is already past the
    /// boundary — this is the SCH-05-style "recovered on restart" path
    /// (PAR-02 AC4): a missed run is not skipped, it fires on next check.
    pub fn computeNextRunDelayMs(self: *PartitionMaintenanceScheduler, now_utc_us: i64, last_run_date: ?[]const u8) u64;

    /// Runs one maintenance cycle: claims today's run-log row (idempotency
    /// gate), creates and attaches any missing future partition through
    /// lead_months, evaluates lead-time severity, and returns a summary.
    /// Safe to call directly (e.g. from an admin-triggered manual run or an
    /// integration test) without going through runDailyLoop()'s sleep loop.
    pub fn runMaintenanceCycle(self: *PartitionMaintenanceScheduler, allocator: std.mem.Allocator) PartitionMaintenanceError!MaintenanceCycleResult;
};
```

`runMaintenanceCycle()` is the unit the acceptance criteria are actually testable against — it is
deliberately separable from `runDailyLoop()`'s sleep/wake mechanics so integration tests can call
it directly without waiting for a real daily boundary, following the same separation
`Scheduler.pollDueTimers()`/`Scheduler.processNextDueTimer()` already establish in this codebase
(a public per-cycle function plus a private sleep-loop wrapper).

### `runMaintenanceCycle()` body sketch (algorithm, not full implementation)

1. `INSERT INTO plat_partition_maintenance_run_log (run_date, future_partition_count) VALUES
   (CURRENT_DATE, 0) ON CONFLICT (run_date) DO NOTHING RETURNING id` — if no row returned,
   return `.{ .ran = false, ... }` immediately (PAR-02 AC2).
2. For each month `m` in `[current_month, current_month + lead_months]` (inclusive, so
   `lead_months = 2` covers 3 months exactly as PAR-01's initial seed did) AND for each `parent`
   in `["events", "events_ephemeral"]` **(REWORK 2: widened from `events` alone — see
   `src/design/par-03-partition-scoped-retention.md`'s "Interaction with the partition structure"
   section; `events_ephemeral` is a write target for `delete`-class routed appends and needs the
   identical lead-time provisioning `events` gets, or a `delete`-class append can hit
   `PartitionMissingForWrite` exactly as an `events`-bound one would)**: check
   `plat_partition_catalog` for an existing `ATTACHED` row with `table_name = <parent> || '_' ||
   to_char(m, 'YYYY_MM')` and `parent_table = <parent>`. If absent, `CREATE TABLE` the candidate
   partition (same CHECK shape as PAR-01's seed loop, `LIKE <parent> INCLUDING DEFAULTS` against
   whichever of `events`/`events_ephemeral` is the current `parent`), call PAR-04's
   `attachPartitionTimed()`, and on `.ok` insert the `plat_partition_catalog` row and append
   `EXECUTION_PARTITION_CREATED` (PAR-02's final AC) carrying the partition name and range bounds.
   On `.attach_scan_required`, return `PartitionMaintenanceError.UnexpectedAttachScanRequired` —
   this job always creates the required CHECKs itself immediately before attaching, so this branch
   indicates a genuine internal defect, not a normal operational path, and is surfaced loudly
   rather than retried silently. This applies identically regardless of which `parent` is being
   provisioned — the CHECK-before-attach discipline is not `events`-specific.
3. Count `ATTACHED` rows in `plat_partition_catalog` with `parent_table = 'events' AND range_start
   > now()` (future partitions — **REWORK 2: this count is explicitly scoped to `parent_table =
   'events'`, not `events_ephemeral`**, since PAR-02 AC3's lead-time severity alarm exists to
   protect ordinary append availability; a `delete`-class type is a small, deliberately-configured
   minority of event types, and a shortfall in `events_ephemeral`'s own future-partition count
   would still surface — just as a `PartitionMissingForWrite` on the next `delete`-class append,
   the same failure mode `events`'s own shortfall produces, not silently). `0` → severity
   `.blocker` (PAR-02 AC3: raised "before any append can fail with `PartitionMissingForWrite`" —
   i.e. this check runs even in the same cycle that just created partitions, so a `lead_months = 0`
   misconfiguration is caught immediately, not just on the next day's run). `1` → `.warn`. `>= 2`
   → `.healthy`.
4. `UPDATE plat_partition_maintenance_run_log SET future_partition_count = $1 WHERE run_date =
   CURRENT_DATE`.
5. Return `.{ .ran = true, .partitions_created = <count from step 2>, .future_partition_count =
   <count from step 3>, .severity = <from step 3> }`.

## Error taxonomy

| Error | Trigger | Surfaced as |
|---|---|---|
| `PartitionMaintenanceError.UnexpectedAttachScanRequired` | PAR-04's check rejects a partition this job just created with matching CHECKs | Job cycle aborts (does not silently skip the month); logged at ERROR severity; the run-log row is NOT marked complete for that month, so the next cycle (or a manually triggered retry) attempts it again |
| `PartitionMaintenanceError.PoolExhausted` / `TransactionFailed` | DB connectivity issue during the cycle | Cycle aborts; `runDailyLoop()` catches and logs, then resumes its sleep loop rather than crashing the background thread — same resilience pattern `Scheduler.pollDueTimers()` already uses for its own per-cycle DB errors |
| `MaintenanceSeverity.blocker` (not a Zig error — a returned enum value) | Zero future partitions remain attached | Caller (the daily loop, or whatever wires this job at startup) is responsible for surfacing this as a paged alert — this design's job logic only classifies severity and returns it; alert delivery (webhook, log line, admin notification) is an integration point this design leaves to BACKEND-DEV's judgment on existing alerting conventions (see Open questions §3) |
| `MaintenanceSeverity.warn` | Exactly one future partition remains | Same delivery caveat as `.blocker`, lower urgency |

## Dependencies

- Depends on: PAR-01's schema (this job creates partitions of the shape PAR-01 defines), PAR-04's
  `verifyAttachConstraints`/`attachPartitionTimed` (`src/db/partition_attach.zig`, this batch),
  SCH-05's already-released missed-run recovery precedent (`src/scheduler/scheduler.zig`'s
  startup-sweep pattern — `is_startup_sweep`, `SCHEDULER_STARTUP_LOCK_ID` — this design's
  `computeNextRunDelayMs()`'s "run immediately if today hasn't happened yet" logic is the same
  underlying idea applied to a daily cadence instead of per-timer `fires_at`, but is a NEW
  function, not a call into `scheduler.zig` itself, since SCH-02's poller is keyed off individual
  `timers` rows and this job has no per-partition "due" row to poll — the run-log table (Migration
  1) is this job's equivalent of "what's due").
- Must NOT depend on: PAR-03's DETACH/ATTACH archival logic (a sibling module this job does not
  call into — PAR-03 runs on its own cadence within the same daily job per the process document's
  Step 8-12 sequencing, but this design treats that sequencing as PAR-03's concern to specify,
  not this one's to assume).
- **Wiring gap this design surfaces rather than resolves:** `src/main.zig` imports
  `scheduler/scheduler.zig` as `scheduler_poller` but this design could not find where
  `Scheduler.init()` is actually called and its background thread spawned (grepped `src/` for
  `Scheduler.init(` outside test files and `Thread.spawn` call sites — none found in
  `main.zig` or an equivalent bootstrap file within the handoff's reading scope). This suggests
  either the production wiring lives in a file this design's reading list did not cover, or SCH-02's
  background thread is not yet started anywhere in `main.zig` as of this batch. BACKEND-DEV
  implementing PAR-02 should locate (or, if genuinely absent, ALSO wire up) the actual
  server-bootstrap call site that starts `Scheduler`'s background thread today, and start
  `PartitionMaintenanceScheduler.runDailyLoop()` alongside it the same way — this design does not
  invent a new bootstrap mechanism, it reuses whatever one already starts SCH-02.

## Open questions

1. **Does this job also need to top up `events_archive`'s own future partition supply?** PAR-01's
   design seeds `events_archive` with the same initial 3 months as `events` (see
   `par-01-monthly-range-partitioning.md`'s Migration 4 and its Open Question §6), but PAR-02's
   body only mentions `events`. Ongoing `events_archive` partition supply for NEW future months
   (as opposed to the CURRENT month's archive-eligible data, which arrives via PAR-03's
   DETACH/ATTACH of an already-existing `events` partition) has no obvious source once the
   initial seed is exhausted, unless PAR-02 is also responsible for keeping `events_archive`'s
   near-term partitions attached in parallel with `events`'s. This design assumes NOT (PAR-02's
   body is `events`-only, and `events_archive` only receives NEW partitions via PAR-03's detach
   cycle in the steady state) but flags this explicitly since the wording is genuinely ambiguous
   and PAR-03's design (this same batch) should confirm or correct this assumption before
   BACKEND-DEV implements either.
2. **`plat_partition_maintenance_run_log` vs. reusing `plat_partition_catalog` for the
   idempotency gate.** This design splits the two concerns into separate tables (one row per
   partition vs. one row per calendar day the job ran) rather than deriving "did today's run
   happen" from `plat_partition_catalog` itself (e.g. "does a row exist with `created_at::date =
   CURRENT_DATE`"). The split was chosen because a day where NO new partition needed creating
   (every month through the lead horizon already attached) would leave no
   `plat_partition_catalog` trace that the job ran at all that day, breaking the idempotency
   check's ability to distinguish "ran today, nothing to do" from "never ran today." This is a
   genuine design choice, not dictated by the requirement text — flagged so
   CODE-DESIGN-VALIDATOR/BACKEND-DEV can confirm the two-table split is accepted rather than
   silently assuming a single-table alternative was intended.
3. **WARN/BLOCKER delivery mechanism.** PAR-02 AC3 says a WARN/BLOCKER "is raised" but does not
   specify the channel (log line, webhook, `EXECUTION_ERROR`-family event, admin API surface).
   This design's `MaintenanceCycleResult.severity` is a return value the caller must act on; it
   does not itself pick a delivery mechanism, since no batch-3 requirement or existing codebase
   convention (grepped for an existing "admin alert"/"paging" module — none found) established
   one. Recommend ORCH/REQ-ANALYST clarify whether a dedicated alerting requirement already
   exists elsewhere in the backlog (the process document's SLA table says "BLOCKER... escalates
   to Platform Admin" and "Platform Admin is paged" for `Adp11GuardTripped`, implying SOME paging
   mechanism is assumed platform-wide) before BACKEND-DEV picks one ad hoc for this job alone.
4. **RESOLVED during PAR-03's REWORK 2: creation loop widened to cover `events_ephemeral`.** This
   job's creation loop (body sketch step 2, Data flow diagram) now provisions future partitions
   for `events_ephemeral` alongside `events`, not `events` alone — driven by PAR-03's addition of
   append-time retention-class routing (`Store.append()` now routes `delete`-class event types to
   `events_ephemeral`), which is a write target needing the same lead-time discipline as `events`.
   See `src/design/par-03-partition-scoped-retention.md`'s "Interaction with the partition
   structure" section for the full rationale. `events_archive` remains excluded from this loop —
   Open questions §1 (above) still applies to it unchanged, since `events_archive` is an archival
   destination populated by PAR-03's DETACH/ATTACH cycle, not a direct append target the way
   `events`/`events_ephemeral` both are. No longer open as a gap; recorded here for traceability
   since this design's original body only ever looped over `events`.
