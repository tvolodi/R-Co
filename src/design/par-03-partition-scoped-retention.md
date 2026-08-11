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

## RetentionClassForbidden guard (PAR-03 AC1) — REWORK 1, was previously missing

PAR-03 AC1, read verbatim from `docs/requirements.yaml`: "GIVEN an event type in the set
`{INSTANCE_*, TASK_*, GATEWAY_*, EXECUTION_*}`, WHEN retention class `delete` is configured for
it, THEN configuration is rejected with `RetentionClassForbidden` and the type never routes to
`events_ephemeral`." This is a **write-time guard on `retention_class`**, distinct from
ADP-11's existing `ProtectedFamilyHardDeleteForbidden` guard on `event_retention_policies.policy`
(`src/event_store/store.zig`'s `validateRetentionPolicyUpsert`/`isProtectedEventFamily`) — that
guard predates `retention_class` (this migration creates the column) and governs a different
table (`event_retention_policies`, ES-07's row-level policy engine, not `event_type_registry`,
the table `retention_class` lives on). The two guards enforce the same underlying prohibition
(protected families never get hard-deleted) at two different configuration surfaces; PAR-03 AC1
requires its own enforcement, not a reference to ADP-11's.

**Call site: `Registry.registerType()`, `src/event_store/registry.zig`.** This is the only
write path to `event_type_registry` in `src/` today (confirmed by grep — no
`src/api/routes/*.zig` file references `event_type_registry` or `registerType`; there is no
admin HTTP route for event-type registration yet). `registerType()` already runs a pure,
DB-connection-free pre-write validation step (`validateRegisterParams`, ISS-0148's pattern:
"validated before any connection opens, so a unit test exercises the production bytes") — the
new check is added to that SAME function, following the identical pattern:

`RegisterParams` gains one new field, defaulted to the non-destructive mode so existing callers
that don't set it keep today's behavior (matching Migration 1's column `DEFAULT
'archive_queryable'` — see Open questions below for why the Zig-side default and the DB-side
`DEFAULT` must be kept in sync as a single atomic unit,
`docs/anti-patterns.md`'s CHECK-constraint/application-constant entry). `RegistryError` gains one
new variant:

```zig
pub const RegisterParams = struct {
    name: []const u8,
    schema_version: u32,
    json_schema: []const u8,
    description: ?[]const u8,
    /// PAR-03: 'retain_forever' | 'archive_queryable' | 'delete'.
    retention_class: []const u8 = "archive_queryable",
};

pub const RegistryError = error{
    // ...existing variants unchanged...
    /// PAR-03 AC1: delete retention_class rejected for a protected family.
    RetentionClassForbidden,
};
```

`validateRegisterParams` (the existing no-DB-access pre-write validation function, ISS-0148's
pattern — "validated before any connection opens, so a unit test exercises the production
bytes") gains one more check, appended after the existing `InvalidJsonSchema` check:

```zig
pub fn validateRegisterParams(params: RegisterParams) RegistryError!void {
    if (params.name.len == 0) return RegistryError.EventTypeNameEmpty;
    if (params.name.len > 128) return RegistryError.EventTypeNameTooLong;
    if (!isJsonObject(params.json_schema)) return RegistryError.InvalidJsonSchema;
    // PAR-03 AC1. Separate prefix check from store.zig's isProtectedEventFamily
    // (private to store.zig, which imports registry.zig, not the reverse) —
    // see Open questions for why this duplication is accepted, same reasoning
    // Open questions §4 already accepted for the SQL-side ephemeral-drop guard.
    if (std.mem.eql(u8, params.retention_class, "delete") and
        isProtectedEventFamilyName(params.name))
    {
        return RegistryError.RetentionClassForbidden;
    }
}

/// PAR-03 AC1's protected-family set, verbatim: {INSTANCE_*, TASK_*,
/// GATEWAY_*, EXECUTION_*}. Private, module-level — matches store.zig's
/// isProtectedEventFamily, which is also private. Both copies must stay in
/// sync if the prefix list ever changes (flagged, not solved, below).
fn isProtectedEventFamilyName(event_type: []const u8) bool {
    return std.mem.startsWith(u8, event_type, "INSTANCE_") or
        std.mem.startsWith(u8, event_type, "TASK_") or
        std.mem.startsWith(u8, event_type, "GATEWAY_") or
        std.mem.startsWith(u8, event_type, "EXECUTION_");
}
```

`registerType()`'s call to `validateRegisterParams(params)` (already the first line of the
function body) now also rejects a `delete` retention_class for a protected-family name, before
any connection is acquired — same fail-fast placement as the existing name/schema checks. On
`RetentionClassForbidden`, `registerType()` returns without ever issuing the `INSERT`, so a
rejected type is never written to `event_type_registry` at all — "the type never routes to
`events_ephemeral`" (AC1's second clause) follows structurally: a type that was never persisted
with `retention_class = 'delete'` can never match the ephemeral-drop guard's or any future
routing logic's selection criteria for `events_ephemeral` placement, since nothing currently
routes an event to `events_ephemeral` except by consulting this same column.

**Second layer — DB-level CHECK constraint (defense-in-depth against direct SQL, not app-only).**
The Zig-side guard above only protects writes that go through `Registry.registerType()`. Nothing
in the current schema stops a direct `UPDATE event_type_registry SET retention_class = 'delete'
WHERE name = 'INSTANCE_STARTED'` from bypassing it entirely — and
`templates/specs/par-03-retention-class.migration.yaml`'s own test scaffold already exercises
raw `UPDATE`/`INSERT` statements against this table directly (its
`retention_class_check_constraint_rejects_unknown_value` case), confirming direct SQL access to
this table is a real, tested surface, not a hypothetical one. Per `docs/anti-patterns.md`'s
"CHECK constraint / application-constant atomic unit" entry, PAR-03 AC1 is exactly the kind of
invariant that should not depend solely on one call path remembering to enforce it. Migration 1
(`migrations/1149_par03_retention_class.sql`) therefore adds a SECOND constraint, alongside the
already-planned `chk_retention_class` value-domain check:

```sql
ALTER TABLE event_type_registry ADD CONSTRAINT chk_retention_class_protected_family
    CHECK (
        retention_class <> 'delete'
        OR split_part(name, '_', 1) NOT IN ('INSTANCE', 'TASK', 'GATEWAY', 'EXECUTION')
    );
```

This mirrors PAR-03's own body verbatim for the ephemeral-drop guard's `split_part(event_type,
'_', 1) IN (...)` predicate — the same prefix-matching idiom applied to `name` instead of
`event_type` (same column semantics: `event_type_registry.name` IS the `event_type` string
appended events carry). A direct SQL write that bypasses `Registry.registerType()` still hits
`23514 (check_violation)`, satisfying `docs/anti-patterns.md`'s "any migration that changes a
CHECK constraint MUST include a corresponding application-constant change in the same commit"
requirement in the SAFER direction: here the CHECK and the app-side guard are added in the very
same migration/handoff, both enforcing the identical rule, so neither can drift out ahead of the
other at the point of introduction (a future prefix-list change to either side without the other
is exactly what Open questions §4's "candidate for a follow-up sync lint" already flags).

**Error taxonomy addition:**

| Error | Trigger | Surfaced as |
|---|---|---|
| `RegistryError.RetentionClassForbidden` | `Registry.registerType()` called with `retention_class = 'delete'` for a name matching `{INSTANCE_*, TASK_*, GATEWAY_*, EXECUTION_*}` (PAR-03 AC1) | Returned to the caller before any connection is acquired (same fail-fast placement as `EventTypeNameEmpty`/`InvalidJsonSchema`); mapped by the eventual admin route (see Access control below) to HTTP 422 — a client input-validation error, not a server fault, consistent with how `UnknownEventType`/`InvalidJsonSchema` are already mapped elsewhere in this module's callers |
| `23514 (check_violation)` on `chk_retention_class_protected_family` | A direct SQL write (bypassing `Registry.registerType()`) sets `retention_class = 'delete'` for a protected-family `name` | Surfaces as a Postgres error to whatever executed the raw SQL; `Store`/`Registry` callers that go through `registerType()` never reach this path in normal operation — it exists as the schema-level backstop, not the primary UX |

**Access control — this is user input, Security checklist applies.** `retention_class` is
platform-admin configuration, not tenant-level data: it changes system-wide archival/deletion
behavior for an entire event type, shared across every tenant appending events of that type (see
PAR-01/PAR-02's `plat_`-prefix precedent for platform-scoped concerns in this same batch).
`event_type_registry` has no `tenant_id` column and is not filtered by `tenant_context` anywhere
in `registry.zig` — it is deliberately global. There is currently no HTTP route exposing
`registerType()`/a `retention_class` update at all (confirmed by grep); this design does not
add one (out of scope — no batch-3 requirement calls for an admin route), but specifies the
access-control requirement for whichever future requirement adds it, so it is not designed
permissively by omission:

- Any future HTTP surface that can set or change `retention_class` (whether via
  `registerType()`'s `RegisterParams.retention_class` or a dedicated update endpoint) MUST gate
  on `actor.is_platform_admin`, following the exact pattern already established at
  `src/api/routes/dlq.zig:238` and `src/api/routes/tasks.zig:854` (`if (actor.is_platform_admin)
  { ... } else return errorResult(allocator, 403, "forbidden");`) — a tenant-scoped actor,
  however privileged within their own tenant, MUST NOT be able to change retention behavior for
  an event type every tenant shares.
- This satisfies `docs/agents/instructions/security-invariants.md` INV-2 (server-side field
  authorisation: the authorization check happens server-side before the mutation, never left to
  a client to avoid sending the field) applied here to a platform-admin-only WRITE rather than
  INV-2's usual READ-side field-stripping scenario — the same "never trust the client to
  self-restrict" principle, at the write boundary instead of the response boundary.
- Until that future route exists, `Registry.registerType()` remains reachable only from
  server-side/test code that already runs with platform-level trust (migrations' seed INSERTs,
  integration tests) — no gap is introduced by this design, since no new externally-reachable
  surface is added.

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
guarded-rebuild + Migration 4 seed-loop pattern exactly.

**REWORK 1 addition:** the CUSTOM block appended after codegen's `ADD COLUMN retention_class`
statement carries TWO constraints, not one — the already-planned value-domain check, and the new
PAR-03 AC1 guard (see "RetentionClassForbidden guard" section above for the full rationale):

```sql
ALTER TABLE event_type_registry ADD CONSTRAINT chk_retention_class
    CHECK (retention_class IN ('retain_forever', 'archive_queryable', 'delete'));

ALTER TABLE event_type_registry ADD CONSTRAINT chk_retention_class_protected_family
    CHECK (
        retention_class <> 'delete'
        OR split_part(name, '_', 1) NOT IN ('INSTANCE', 'TASK', 'GATEWAY', 'EXECUTION')
    );
```

Both are added in the SAME migration/commit as `Registry.registerType()`'s Zig-side
`RetentionClassForbidden` guard (also this rework) — the atomic-unit requirement
`docs/anti-patterns.md` states for CHECK constraints and the application logic that feeds them
is satisfied by construction here, since both are introduced together rather than one preceding
the other.

It is hand-written in the SAME generated migration file, following PAR-01's Migration 1
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

## `Store.archive()` retirement (PAR-03 DELETE-prohibition, REWORK 1) — scope for BACKEND-DEV

CODE-DESIGN-VALIDATOR's BLOCKER 2 required this ambiguity closed without a REQ-ANALYST detour:
PAR-03's body — "No `DELETE` statement SHALL run against `events` or `events_archive` at any
point" — names the tables directly, with no mechanism-scoping qualifier, unlike PAR-01 AC2's
explicit "partitioning does not narrow idempotency to a per-month scope" phrasing when a
local-vs-global distinction IS intended. Read literally (the validator's required "defensive"
reading when genuinely ambiguous), this forbids `DELETE FROM events`/`DELETE FROM events_archive`
from EVERY code path, not only PAR-03's own new mechanism. `Store.archive()`
(`src/event_store/store.zig:947-1164`) issues exactly that DELETE, so it must not survive this
batch as reachable, compiled code — this closes the AC-compliance question under BOTH readings of
the ambiguous text simultaneously, rather than betting on the narrower one.

**Verified before deciding removal was tractable** (read `Store.archive()` in full, all 218
lines, and every one of its 5 calling integration tests in full — not assumed from the function
signature):

- **Zero `src/` call sites**, confirmed independently of CODE-DESIGN-VALIDATOR's own grep: `main.zig`
  constructs `event_store.Store` (`ev_store`) but never calls `.archive()` on it; no scheduler,
  cron, or HTTP route reaches it. The three `store.archive(allocator, id)` sites in
  `src/api/routes/definitions.zig` resolve to the unrelated `definition.Store.archive()`
  (`src/definition/store.zig:833`, a workflow-definition ACTIVE/DEPRECATED→ARCHIVED status
  transition with no `events`/`events_archive` interaction at all — confirmed by reading that
  function's signature and body, not inferred from the name alone). So removal breaks no live
  request path.
- **NOT a clean, consequence-free deletion**, however: `Store.archive()` is the ONLY executable
  implementation of ES-07's row-level archival-move mechanics (SHOULD, RELEASED —
  `docs/requirements.yaml`) and is the sole thing driving 4 of `tests/specs/ADP-11.md`'s traced
  test cases for ADP-11 (MUST, RELEASED): `TC-ES-07-01`, `TC-ES-07-02`, `TC-ADP-11-02`,
  `TC-ADP-11-03` (all in `tests/integration/event_store_integration_test.zig`) call
  `store.archive(alloc, ...)` directly and assert on the resulting `events`/`events_archive` row
  counts. `TC-ADP-11-01` is unaffected — it calls only `upsertRetentionPolicy()` (config-time
  rejection, ADP-11's OWN stated AC verbatim: "Attempting to set hard deletion on
  `INSTANCE_STARTED` is rejected with a structured error") and never touches `archive()`.
  `upsertRetentionPolicy()` itself is NOT removed by this design — only `archive()`, its sole
  downstream consumer, is.

**Why removal is the correct scope, not a rewrite-to-redirect:** PAR-03's DETACH/ATTACH mechanism
operates at whole-PARTITION (whole-calendar-month) granularity; `archive()` operates at
arbitrary-row granularity selected by a per-event-type `keep_days`/`keep_count` policy matched
against individual `created_at`/`sequence_number` values. There is no mechanical redirect from
one to the other — a row-level selection predicate cannot be re-expressed as "detach this whole
partition" without silently changing ES-07's actual policy semantics (a `keep_days=7` policy does
not mean "detach whichever whole months happen to be older than 7 days"). This is precisely why
PAR-03's Module purpose section already states its mechanism "supersedes" ES-07's row-level engine
"for the protected families" rather than reimplementing it — the two are different retention
models, not two implementations of the same one. Rewriting `archive()` to call into
`PartitionRetention` would therefore misrepresent what it does; removal is the honest scope.

**Exact removal scope for BACKEND-DEV (this batch, same commit as the migration/registry
changes above — not a separate follow-up):**

1. Delete `Store.archive()` (`src/event_store/store.zig`, the `// archive (ES-07)` section
   header through the function's closing brace, currently lines 933-1164) in its entirety,
   including its doc comment.
2. `upsertRetentionPolicy()` and `RetentionPolicyMode`/`RetentionPolicyUpsertParams`/
   `RetentionPolicyViolation`/`retentionPolicyErrorCode`/`retentionPolicyViolation`/
   `isProtectedEventFamily`/`validateRetentionPolicyUpsert` are NOT removed — they implement
   ADP-11's own AC (config-time rejection), which does not touch `events`/`events_archive` rows
   and is not in conflict with PAR-03. `TC-ADP-11-01` continues to pass unchanged.
3. Rewrite the 4 affected tests in `tests/integration/event_store_integration_test.zig`:
   - `TC-ES-07-01` (line 1003) and `TC-ES-07-02` (line 2160): these test ES-07's archival-move
     mechanics specifically (SHOULD-priority, not MUST) — since the mechanism under test no
     longer exists, replace the `store.archive(alloc, ...)` call and the post-call
     `events`/`events_archive` count assertions with an explicit `error.SkipZigTest` is
     FORBIDDEN by `docs/anti-patterns.md`'s "no `SkipZigTest` on a MUST/requirement test without a
     separately passing integration test" entry — but ES-07's mechanics are not simply skipped
     here, they are retired along with the code that implemented them. Convert both to assert the
     RETIREMENT itself is real and permanent: `upsertRetentionPolicy()` can still be configured
     for these event types, but no code path in `src/` acts on that configuration by moving rows
     (a `grep -c "fn archive" src/event_store/store.zig` returning 0, asserted at the SOURCE level
     via a small `tests/unit/` or `tools/` check, is one option — BACKEND-DEV's call which concrete
     form this takes, since it is implementation detail, not a schema/design decision). Rename
     both tests to state what they now verify (e.g. `TC-ES-07-01: archive() row-level mechanism is
     retired; no DELETE against events/events_archive exists in src/`) and update
     `tests/specs/ES-01-08.md`'s `## ES-07` section to record that its archival-move AC is
     transferred to PAR-03's `PartitionRetention.runArchivalAging()`/`runEphemeralDrop()` (already
     designed, this same batch, above) as the mechanism's replacement, once BACKEND-DEV implements
     that Type E module later in this same workflow.
   - `TC-ADP-11-02` (line 1124) and `TC-ADP-11-03` (line 1203): these are `tests/specs/ADP-11.md`'s
     FORMALLY TRACED evidence for 2 of ADP-11's 4 acceptance areas ("non-protected ES-07
     hard-delete configurability preserved" and "protected archive/queryability replay-safety
     invariant") — a MUST, RELEASED requirement. Since the archival mechanism itself transfers to
     PAR-03 (previous bullet), these two test cases' INTENT (non-protected families keep
     hard-delete configurability; protected families' archived rows stay queryable) is preserved
     by repointing them at PAR-03's `PartitionRetention` module instead of `Store.archive()`, in
     the SAME follow-through this batch already schedules for that module's own TEST-DESIGNER
     pass. Update `tests/specs/ADP-11.md`'s `Implemented by:` lines for these two cases once the
     replacement tests exist. This is a same-workflow handoff to TEST-DESIGNER, not a deferred
     follow-up requirement — `src/scheduler/partition_retention.zig` (this design, above) is being
     built in this same WF-02 run.
4. Confirm via `git grep -n "DELETE FROM events\b\|DELETE FROM events_archive\b" src/` returns
   zero results after step 1 — the mechanical proof that no `src/` code path violates PAR-03's
   DELETE-prohibition under either reading, closing BLOCKER 2 unambiguously.

This is a same-batch implementation task (BACKEND-DEV Step 02, TEST-DESIGNER Step 03 of THIS
workflow), not a "recommend ORCH schedule a follow-up requirement" deferral — the deferral
language this design previously carried is removed (see Open questions §1, below, superseded).

## Dependencies

- Depends on: PAR-01's schema (`events`/`events_archive`/`plat_event_idempotency`), PAR-02's
  `plat_partition_catalog` (state tracking) and `runMaintenanceCycle()` (the caller), PAR-04's
  `attachPartitionTimed()` (the re-attach step), ADP-11's already-released
  `isProtectedEventFamily()` logic in `src/event_store/store.zig` (this design's ephemeral-drop
  guard reimplements the SAME family-prefix check as a SQL predicate rather than calling the Zig
  function, since the guard runs as a single `SELECT count(*)` against the partition, not a
  per-row Zig-side check — see Open questions §4 for why this duplication is accepted rather than
  factored out).
- Must NOT depend on: `Store.archive()` (`src/event_store/store.zig`) — this function is REMOVED
  by this same batch (see "`Store.archive()` retirement" section above), not merely avoided; this
  module does not call it, and after BACKEND-DEV's removal it no longer exists to call.

## Open questions

1. **RESOLVED during REWORK 1: `Store.archive()` overlap.** Previously this section recommended
   deferring `archive()`'s retirement to a follow-up requirement or WF-03 issue. CODE-DESIGN-VALIDATOR
   (Step 1b) correctly rejected that as an unresolved ambiguity being guessed at rather than
   flagged (BLOCKER 2): PAR-03's "No `DELETE` statement SHALL run against `events` or
   `events_archive` at any point" is genuinely ambiguous between an absolute, codebase-wide
   prohibition and a narrower "PAR-03's own mechanism never deletes" reading. Per the validator's
   own instruction ("design defensively to the literal/stricter reading... schedule archive()'s
   retirement/gating explicitly within this batch"), this design now specifies `Store.archive()`'s
   full removal as in-scope, same-batch, same-commit work — see "`Store.archive()` retirement"
   section above for the exact removal scope, the verification that removal breaks no live call
   site, and the explicit disposition of its 5 dependent tests (1 unaffected, 4 rewritten/repointed
   at PAR-03's own `PartitionRetention` module rather than silently dropped). This closes the
   AC-compliance question under EITHER reading of the ambiguous text: after removal, zero `DELETE`
   statements against `events`/`events_archive` exist anywhere in `src/`, so the literalist
   reading is satisfied trivially and the narrower reading was already satisfied by construction.
   No REQ-ANALYST business-interpretation detour is needed because the design no longer depends on
   which reading is "correct" — both are satisfied simultaneously. No longer open.
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
