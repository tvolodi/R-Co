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

## Append-time retention-class routing (PAR-03, REWORK 2 — was missing)

`docs/processes/system/event-log-partitioning.md` Step 7, verbatim: "Event Store routes each
append by the event type's retention class: `retain_forever` and `archive_queryable` ->
`events`; `delete` -> `events_ephemeral`." CODE-DESIGN-VALIDATOR's rework-2 BLOCKER is correct
that nothing in this design (through REWORK 1) implements this — the `RetentionClassForbidden`
guard added in REWORK 1 stops a protected-family type from ever being *configured* with
`retention_class = 'delete'`, but says nothing about where a NON-protected `delete`-class type's
events actually get written. Without this routing, `PartitionRetention.runEphemeralDrop()`
(above) always finds zero attached `events_ephemeral` partitions with any rows in them — the
mechanism exists but nothing ever feeds it. This section closes that gap.

### Where the retention_class lookup happens in `Store.append()`

Read in full: `src/event_store/store.zig`'s `append()` (lines 236-540) and
`src/event_store/registry.zig`'s `validatePayload()`/`getType()` (lines 178-284).

`append()` already calls `self.registry.validatePayload(allocator, params.event_type,
params.payload)` at line 262, BEFORE the transaction opens (ES-05 pre-write validation).
Internally, `validatePayload()` calls `self.getType(allocator, event_type)` (line 188) to fetch
the `EventTypeRecord` it validates the payload against — but only to read `.json_schema`; the
rest of the record, including everywhere `retention_class` would live, is discarded via `defer
freeTypeRecord(allocator, record)` immediately after schema validation completes.
`validatePayload()`'s own signature returns `RegistryError!void` — no record data survives the
call.

**Design decision: do NOT widen `validatePayload()`'s signature.** `validatePayload()` is a
released ES-05 interface, documented in `src/design/event_store.md` (line 174) with a `void`
return type, and has exactly one call site outside `registry.zig` itself
(`store.zig:262`, confirmed by `grep -rn "validatePayload(" src/ tests/`). Changing its return
type would mean editing an already-released design artefact outside this batch's scope
(PAR-01/02/03/04 only) for a saving of one query. Instead:

- `EventTypeRecord` (registry.zig, line 50) gains one new field:
  ```zig
  pub const EventTypeRecord = struct {
      id: Uuid,
      name: []const u8,
      schema_version: u32,
      json_schema: []const u8,
      description: ?[]const u8,
      created_at: i64,
      updated_at: i64,
      /// PAR-03: 'retain_forever' | 'archive_queryable' | 'delete'.
      /// DEFAULT 'archive_queryable' at the DB level (Migration 1) — a row
      /// written before this migration ran (impossible in this batch's
      /// target fresh-migrated environment, see PAR-01's Scoping note, but
      /// defensive regardless) reads back as 'archive_queryable', the
      /// non-destructive default, never as 'delete'.
      retention_class: []const u8 = "archive_queryable",
  };
  ```
  Confirmed additive/non-breaking: `EventTypeRecord{}` is constructed in exactly two places
  (both inside `registry.zig` — `registerType()`'s placeholder-record return and `getType()`'s
  real-row parse), and `getType()`'s one external caller
  (`src/api/routes/instances.zig:896`) only reads fields off the returned record for a
  success/error signal, never constructs one itself (confirmed by reading that call site in
  full) — adding a field with a Zig-level default breaks neither.
- `getType()`'s SELECT (registry.zig, line 231) adds the new column:
  ```sql
  SELECT id, name, schema_version, json_schema, description,
         EXTRACT(EPOCH FROM created_at)::bigint * 1000000,
         EXTRACT(EPOCH FROM updated_at)::bigint * 1000000,
         retention_class
  FROM event_type_registry
  WHERE name = $1
  ORDER BY schema_version DESC
  LIMIT 1
  ```
  and the row-parse block gains `rec.retention_class = allocator.dupe(u8, colText(row, 7) orelse
  "archive_queryable") catch return RegistryError.TransactionFailed;` (same allocation/error
  pattern as the existing `rec.name`/`rec.json_schema` dupes immediately above it in the current
  function body) — freed by the existing `freeTypeRecord()` helper, which gains one more
  `allocator.free(record.retention_class)` line alongside its existing three frees.
- `Store.append()` adds ONE new call, immediately after the existing `validatePayload()` call
  (store.zig, after line 267) and still BEFORE the transaction's `BEGIN` (line 306) — i.e. still
  inside the pre-write validation phase, no DB writes committed yet either way:
  ```zig
  // PAR-03: retention-class routing. A second getType() call — validatePayload()
  // (above) already fetched this row internally but discards everything except
  // json_schema. Not folded into one call: validatePayload()'s signature is a
  // released ES-05 interface (src/design/event_store.md) not touched by this
  // batch. Two SELECT-by-indexed-name queries against event_type_registry per
  // append (already a per-append cost today, since validatePayload() does one)
  // is an accepted, explicitly-flagged cost — see Open questions below.
  const type_record = self.registry.getType(allocator, params.event_type) catch |err| switch (err) {
      registry_mod.RegistryError.UnknownEventType => return StoreError.UnknownEventType,
      registry_mod.RegistryError.PoolExhausted => return StoreError.PoolExhausted,
      else => return StoreError.TransactionFailed,
  };
  defer registry_mod.Registry.freeTypeRecord(allocator, type_record);
  const target_table: []const u8 = if (std.mem.eql(u8, type_record.retention_class, "delete"))
      "events_ephemeral"
  else
      "events";
  ```
  `UnknownEventType` cannot actually trigger here in practice (the identical lookup already
  succeeded inside `validatePayload()` moments earlier, same transaction-less pre-write phase,
  same `event_type` string, no DB write has happened between the two calls that could delete the
  type) — the branch exists for defensive completeness (a concurrent `DROP`/de-registration
  between the two calls, however unlikely) rather than an expected runtime path, consistent with
  how this design already treats `AttachScanRequired` inside `runArchivalAging()` as
  "should not occur in practice."

### What determines the SQL target table

`target_table` (above) is a compile-time-known one-of-two string, never user input, never
interpolated from `params`— it selects between two fixed, hand-written SQL statement bodies at
the Zig level (Zig has no parameterised-identifier placeholder; `$N` placeholders only bind
values, never table names, so `target_table` cannot be passed as a bind parameter regardless of
trust level). `append()`'s Step 3 INSERT (store.zig lines 402-437) becomes an `if
(std.mem.eql(u8, target_table, "events_ephemeral"))` branch selecting between two literal SQL
strings — identical column list and `$N` positions in both branches (`events_ephemeral`'s column
set, Public interface section above, is deliberately identical to `events`'s own column set
minus nothing — same 11 columns), differing only in the `INSERT INTO <table>` clause and,
correspondingly, which table the `ON CONFLICT (idempotency_key) DO NOTHING` targets. **This
routing does not change the duplicate-detection fallback logic** (store.zig lines 444-499, "check
`events` then `events_archive`"): a `delete`-class event type's idempotency key is still checked
against wherever PAR-01's `plat_event_idempotency` sidecar (or, pre-PAR-01-in-the-same-commit,
the legacy `events`/`events_archive` two-table check) resolves it — `events_ephemeral` does not
get its own separate idempotency scope; PAR-01 AC2's "global idempotency-key uniqueness" already
covers every append regardless of destination table, since `plat_event_idempotency` is written in
the same transaction as every append (PAR-01's design, Migration 2 + Open questions §3),
independent of which of the three tables (`events` / `events_archive` / `events_ephemeral`) the
event row itself lands in. This design adds `events_ephemeral` as a third possible resolution
target for the duplicate-fetch fallback path: if `plat_event_idempotency` resolves a duplicate
key to an `(event_id, created_at)` pair, the caller must check all three tables for the actual
row (or, more precisely, know from `event_type_registry.retention_class` which one to check
first) — see Open questions below for why this is flagged rather than fully pinned down here.

### Interaction with `plat_event_idempotency` (PAR-01, same batch)

No special-casing needed: `plat_event_idempotency (idempotency_key PK, event_id, created_at)` is
written in the same transaction as the event row regardless of which of `events` /
`events_ephemeral` receives the INSERT — PAR-01 AC2's global-uniqueness guarantee does not
distinguish by destination table, and nothing about `plat_event_idempotency`'s own shape
(Migration 2, PAR-01's design) references `events` by name or FK. The two-statement ordering
PAR-01's Open questions §3 already recommends (insert `plat_event_idempotency` first, branch on
whether it returned a row, THEN insert the event row into whichever of `events`/`events_ephemeral`
`target_table` selects) composes cleanly with this routing: the retention-class lookup
(`target_table` selection, above) can happen any time before that second INSERT is issued — this
design places it in the pre-transaction validation phase (before `BEGIN`) purely because that is
where `validatePayload()` already runs, not because the transaction requires it there.

### Interaction with the partition structure — does `events_ephemeral` need monthly partitioning?

**Yes, same monthly-partition shape as `events`/`events_archive`, not structured differently.**
This is already implied by two things this design produced BEFORE rework 2 but did not connect
explicitly until now:

1. The Public interface section (Migration 1) already declares `events_ephemeral` as `PARTITION
   BY RANGE (created_at)` with `PRIMARY KEY (event_id, created_at)` — the identical shape as
   `events`.
2. `runEphemeralDrop()`'s data-flow diagram (above) already queries `plat_partition_catalog WHERE
   parent_table = 'events_ephemeral' AND state = 'ATTACHED' AND range_end < now() -
   ephemeral_drop_after_months` — i.e. it already assumed per-month `events_ephemeral_YYYY_MM`
   partitions exist, tracked the same way as `events_YYYY_MM`/`events_archive_YYYY_MM` rows in
   `plat_partition_catalog` (PAR-02's table, generic across all three `parent_table` values by
   design — its `parent_table`/`table_name`/`state` columns carry no `events`-specific
   assumption).

What was missing is that nothing populated `events_ephemeral` with actual data, and nothing in
PAR-02's `runMaintenanceCycle()` creation loop (Step 8-9 of the process doc) explicitly names
`events_ephemeral` as a THIRD parent to proactively create future partitions for, alongside
`events`/`events_archive` — it currently only mentions creating `events_YYYY_MM`
(`src/design/par-02-partition-maintenance-job.md`'s "`runMaintenanceCycle()` body sketch" step 2
loops over months and creates ONE partition per month, worded around `events` only). **This is a
real, distinct gap from the append-time routing gap**, and this design extends PAR-02's creation
loop to cover `events_ephemeral` as well:

- PAR-02's `runMaintenanceCycle()` step 2 (its design doc) is extended: for each month `m` in
  `[current_month, current_month + lead_months]`, the loop now creates/attaches a partition for
  ALL THREE of `events`, `events_archive`, `events_ephemeral` (not just `events`) — mirroring
  exactly how PAR-01's own Migration 4 initial-seed loop already double-seeds
  `events_YYYY_MM`/`events_archive_YYYY_MM` together in one `FOR v_offset IN 0..2` loop body (see
  `src/design/par-01-monthly-range-partitioning.md`, Migration 4). `events_ephemeral` needs
  future partitions attached ahead of need for the identical reason `events` does: a `delete`-
  class append landing in a month with no attached `events_ephemeral_YYYY_MM` partition fails
  with `PartitionMissingForWrite` exactly as an `events`-bound append would (this design's
  `target_table` branch, above, does not special-case which table's missing-partition error is
  "less severe" — PAR-01 AC4's error applies identically to whichever of the two tables the
  routing decision selected).
- This is a small, additive extension to PAR-02's already-produced design (widening one loop from
  two tables to three), not a rewrite — flagged here rather than left unstated, and mirrored in
  `par-02-partition-maintenance-job.md` directly (see the cross-reference added to that file's own
  Open questions, if BACKEND-DEV finds it needs updating there too — see Open questions below for
  why this design does not itself edit `par-02`'s file body beyond this note).
- Ephemeral partitions ARE still "periodically fully dropped" (per this design's own
  `runEphemeralDrop()`, unchanged by this section) — proactive creation ahead of need and
  eventual `DROP TABLE` once aged past `ephemeral_drop_after_months` are not in tension: every
  `events`-family table (including `events_archive`, which is itself just a long-term parking
  parent for detached `events` partitions) is created ahead of need and only later transitions to
  its terminal state (archived-forever for `events_archive`, dropped for `events_ephemeral`).
  `events_ephemeral` partitions are NOT created with a shorter lookback/lookahead window than
  `events`/`events_archive` — same `lead_months` horizon, same monthly grain — because the
  routing decision (which table an event lands in) is made per-EVENT at append time, not
  per-PARTITION at creation time; the maintenance job cannot know in advance whether a given
  future month will receive any `delete`-class events, so it provisions the partition
  unconditionally, identically to how it provisions an `events_YYYY_MM` partition without knowing
  in advance whether any event will actually be appended to it that month.

## Data flow diagram

```
Store.append(allocator, params)                              [REWORK 2 addition]
        |
        |-- self.registry.validatePayload(...)  (existing, ES-05, unchanged)
        |-- self.registry.getType(allocator, params.event_type)
        |         |
        |         v
        |   type_record.retention_class == 'delete'?
        |         | no (retain_forever / archive_queryable)  | yes
        |         v                                          v
        |   target_table = "events"                    target_table = "events_ephemeral"
        |         |                                          |
        |         +------------------------+-------------------+
        |                                  v
        |                     BEGIN; ...; INSERT INTO <target_table> (...)
        |                     ON CONFLICT (idempotency_key) DO NOTHING
        |                     RETURNING ...; ...; COMMIT
        v
   (unaffected: instance/sequence checks, plat_event_idempotency write,
    event_payload_store side-table insert, instance_projections update —
    all identical regardless of target_table)
```

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

### `src/event_store/registry.zig` changes (REWORK 2, append-time routing support)

```zig
pub const EventTypeRecord = struct {
    id: Uuid,
    name: []const u8,
    schema_version: u32,
    json_schema: []const u8,
    description: ?[]const u8,
    created_at: i64,
    updated_at: i64,
    /// PAR-03 (rework 2): 'retain_forever' | 'archive_queryable' | 'delete'.
    retention_class: []const u8 = "archive_queryable",
};
```

`getType()`'s SELECT gains `retention_class` as an 8th column; `freeTypeRecord()` gains
`allocator.free(record.retention_class)`. See "Append-time retention-class routing" above for the
full rationale and exact diff shape.

### `src/event_store/store.zig` changes (REWORK 2, append-time routing)

`Store.append()` gains one new pre-transaction call (`self.registry.getType()`) and one new
`target_table` selection, both detailed in full in "Append-time retention-class routing" above.
Step 3's INSERT (currently a single hard-coded `INSERT INTO events (...)`) becomes two SQL string
literals selected by `target_table`, identical in every column/placeholder position, differing
only in the table name in the `INSERT INTO` / implicit `ON CONFLICT` target. No new `StoreError`
variant is required — `UnknownEventType`/`PoolExhausted`/`TransactionFailed` (all pre-existing)
cover every failure mode of the new `getType()` call.

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
| `StoreError.UnknownEventType` (REWORK 2, `Store.append()`'s new `getType()` call) | The routing lookup's `event_type` is not found in `event_type_registry` | Defensive-only branch — the identical lookup already succeeded moments earlier inside `validatePayload()` in the same pre-transaction phase, so this should be unreachable in normal operation (see "Append-time retention-class routing" above); mapped to the same HTTP 422 `validatePayload()`'s own `UnknownEventType` already produces, so no new client-visible error code is introduced |
| `StoreError.PartitionMissingForWrite` (PAR-01, applies identically to `events_ephemeral`, REWORK 2) | A `delete`-class append's `created_at` falls in a month with no attached `events_ephemeral_YYYY_MM` partition | Same error, same HTTP 503 mapping as an `events`-bound append hitting a missing partition (PAR-01's error taxonomy) — this design's routing does not introduce a second error for the ephemeral case; PAR-02's creation loop, extended by this design (see "Interaction with the partition structure" above) to also provision `events_ephemeral` partitions ahead of need, is what prevents this in steady-state operation |

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

     **REWORK 2 — `TC-ADP-11-02`'s rewrite is now concretely groundable, not merely a placeholder
     redirect.** Before this rework, "repoint at `PartitionRetention`" had no real mechanism behind
     it: nothing populated `events_ephemeral` with any rows, so a rewritten test could only call
     `runEphemeralDrop()` against an empty partition and trivially assert "0 dropped, 0 guard
     trips" — not actually exercising "non-protected families retain hard-delete
     configurability." With the append-time routing above (`Store.append()` -> `getType()` ->
     `target_table` selection), the rewritten test now has a real, traceable end-to-end path:
     register a non-protected event type (e.g. `WIDGET_CREATED`) via `Registry.registerType()`
     with `retention_class = 'delete'` (permitted — `WIDGET_*` does not match
     `{INSTANCE_,TASK_,GATEWAY_,EXECUTION_}*`, so REWORK 1's `RetentionClassForbidden` guard does
     not reject it), append one or more events of that type via `Store.append()` and assert the
     row lands in `events_ephemeral` (not `events`) — e.g. `SELECT count(*) FROM events_ephemeral
     WHERE event_type = 'WIDGET_CREATED'` returns the expected count and the equivalent query
     against `events` returns 0 — then either (a) directly assert on `events_ephemeral`'s content
     as the full test, since "hard-delete configurability preserved" is now demonstrated by the
     routing itself (the type WAS configured for hard deletion, and its events WERE routed to the
     table `DROP TABLE` operates on), or (b) additionally drive a full cycle: advance/backdate the
     partition's `range_end` past `ephemeral_drop_after_months` (or construct the test partition
     with an already-aged range directly, matching how `runArchivalAging()`'s own tests are
     expected to backdate `plat_partition_catalog` rows — implementation-test-design judgment for
     TEST-DESIGNER, not dictated here) and call `PartitionRetention.runEphemeralDrop()`, asserting
     the partition is dropped and the guard was never tripped (count of protected-family rows in
     that partition is legitimately 0, since `WIDGET_CREATED` was never protected-family to begin
     with). Either form is now backed by real, designed behavior — routing decides WHERE the row
     goes, `runEphemeralDrop()` decides WHEN the table holding it goes away — closing the gap
     CODE-DESIGN-VALIDATOR's rework-2 BLOCKER identified. `TC-ADP-11-03` (protected-family
     archive/queryability) is unaffected by this addition — protected families never route to
     `events_ephemeral` at all (REWORK 1's guard), so that test's path continues to run entirely
     through `runArchivalAging()`/`events_archive`, exactly as REWORK 1 already specified.
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
- **REWORK 2 addition:** `Store.append()` (`src/event_store/store.zig`) now depends on
  `Registry.getType()`/`EventTypeRecord.retention_class` (`src/event_store/registry.zig`) for the
  append-time routing decision — see "Append-time retention-class routing" above. This is a new
  cross-module dependency this design introduces (PAR-03's migration adds the column;
  `store.zig`'s append path reads it), the inverse direction of PAR-03's existing dependency on
  ADP-11's `isProtectedEventFamily()` (that one is store.zig -> registry.zig's *sibling*, i.e.
  store.zig already imports `registry.zig` today per its own top-of-file `const registry_mod =
  @import("registry.zig")`, confirmed by reading store.zig's imports — no NEW module edge is
  created, only a new call through an already-existing import).
- **REWORK 2 addition:** PAR-02's `runMaintenanceCycle()` creation loop now also depends on
  `events_ephemeral` existing as a third partition family to provision ahead of need (see
  "Interaction with the partition structure" above) — a small, additive extension to PAR-02's
  already-produced design that this document specifies but does not itself rewrite line-by-line in
  `par-02-partition-maintenance-job.md`'s body (see Open questions §5 for why).
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
5. **NEW (REWORK 2): `par-02-partition-maintenance-job.md`'s creation-loop body is not directly
   edited by this document.** "Interaction with the partition structure" (above) specifies that
   PAR-02's `runMaintenanceCycle()` step 2 must provision `events_ephemeral` partitions ahead of
   need, alongside `events`/`events_archive` — but the authoritative step-2 algorithm sketch lives
   in `par-02-partition-maintenance-job.md`, a separate, already-produced design artefact for a
   different requirement (PAR-02). This document specifies the REQUIREMENT (three parents, not
   two, in the same loop) and the REASON (`delete`-class events need a target partition exactly as
   much as any other class does), which is sufficient for BACKEND-DEV to implement correctly, but
   does not itself rewrite `par-02`'s Public Interface section to show the three-table loop body
   verbatim — that edit is applied directly to `par-02-partition-maintenance-job.md` as a
   companion change in this same rework pass (see that file's own changelog/diff for the loop-body
   update), keeping each requirement's authoritative algorithm description in its own file rather
   than duplicating PAR-02's pseudocode inside PAR-03's document. Not left silently inconsistent
   between the two files — cross-referenced explicitly in both directions.
6. **NEW (REWORK 2, genuinely open, not a compliance gap): duplicate-fetch fallback across three
   tables.** `Store.append()`'s post-`ON CONFLICT DO NOTHING` fallback path (store.zig lines
   444-499) currently checks `events` then `events_archive` for a pre-existing duplicate row, and
   PAR-01's design already updates this to resolve via `plat_event_idempotency` first (Open
   questions §3 there) before reading the correct table. This design's routing adds a THIRD
   candidate table (`events_ephemeral`) that a `delete`-class type's duplicate could live in. The
   `plat_event_idempotency` row itself does not record WHICH of the three tables the original
   event landed in (its schema, PAR-01 Migration 2, is `idempotency_key, event_id, created_at` —
   no table-name column) — so resolving a duplicate for a `delete`-class event type requires either
   (a) re-deriving `target_table` the same way the original append did (a second
   `registry.getType()` call keyed by the SAME `event_type`, which the caller already has from
   `params.event_type` even in the duplicate branch), or (b) adding a `source_table` column to
   `plat_event_idempotency` so the duplicate-fetch path never needs a second registry lookup. This
   design recommends (a) — it requires no schema change to PAR-01's already-produced
   `plat_event_idempotency` table and reuses the exact `target_table` derivation this document
   already specifies for the primary insert path — but does not mandate it, since the two-line
   difference between (a) and (b) is BACKEND-DEV implementation-shape judgment, not a schema
   decision this design artefact is required to pin down. **This is NOT a gap that blocks PAR-03's
   own acceptance criteria** (no PAR-03 AC concerns the duplicate-fetch fallback path's exact
   table-resolution order; ES-03's "return the original event" behavior is satisfiable by either
   (a) or (b)) — flagged here as an implementation-shape open question for BACKEND-DEV, not left
   silently unresolved as if it were undiscovered.
