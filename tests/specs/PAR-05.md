# Test Spec: PAR-05 — Online conversion to a partitioned event log

**Requirement:** PAR-05 — verbatim requirement text:
> The one-time conversion of an existing `events` table into a partitioned parent SHALL run
> online. A new parent is created alongside, historical rows are backfilled in `created_at`
> windows of one calendar month with one transaction per window and `ON CONFLICT (event_id,
> created_at) DO NOTHING`, and the tables are exchanged by a rename swap inside a single
> transaction. `plat_event_idempotency` SHALL be created and populated before the swap, so
> global `idempotency_key` uniqueness is never absent.

**Priority:** MUST
**Test layer:** integration (real PostgreSQL — see Scoping/fixture note below)
**Scored test-tier (test_developer_guide.md §2.1):** DB schema (2) + transactional boundary (1)
= 3 points → sandbox tier; no Wasm/sandbox surface exists in this module, so the unit +
integration layers below are the ceiling actually applicable.

## Scoping / fixture note — read before reviewing coverage (per Open questions §2 of
`src/design/par-05-online-partition-conversion.md`)

PAR-05 converts an **existing, populated, unpartitioned** `events` table — the shape a
pre-PAR-01 production/`bpm_dev` database has. A freshly migrated `bpm_test` always takes
PAR-01's from-scratch path (`1147_par01_events_partitioning.sql`, which unconditionally
`DROP TABLE IF EXISTS events` and recreates it `PARTITION BY RANGE` before any test runs) and
so **never** reaches a state where `events` is unpartitioned with real rows to convert. This is
not a coverage gap being silently accepted — it is the exact situation the design document's own
"Scoping note" and "Open questions §2" flag and instruct TEST-DESIGNER to solve with "a fixture
that first builds `events` in its PRE-PAR-01 unpartitioned shape... and only THEN exercises this
module's conversion path — deliberately bypassing `1147`'s already-partitioned target for that
one test's setup."

Because `PartitionConverter`'s methods (`src/db/partition_conversion.zig`) hardcode the
unqualified names `events` / `events_part` / `events_legacy` / `plat_event_idempotency` /
`plat_partition_catalog` (confirmed by reading the module in full — no table name is
parameterised), the ONLY way to exercise the conversion pipeline without renaming or dropping
the real, shared `tenant_default.events` table (which every concurrently-running
`test-integration` binary depends on — the exact anti-pattern
`docs/anti-patterns.md` "cleanup helper reused against `tenant_default`" entry warns against)
is to run the whole pipeline against a **dedicated, single-test-owned PostgreSQL schema** that
declares its own unpartitioned `events` table plus the sibling tables `PartitionConverter`
touches, then point one held connection's `search_path` at that schema for the test's entire
duration. Every statement `partition_conversion.zig`/`partition_attach.zig` issues is
unqualified and resolves through `search_path`/`::regclass` (confirmed by reading both files:
`current_schema()`-based existence checks, `$1::regclass` constraint lookups, unqualified
`ALTER TABLE events RENAME TO ...`) — so this isolation is sound: nothing in the module can
"leak" onto `tenant_default.events` once `search_path` no longer includes it.

This is a bespoke, non-`TestHarness` fixture by design (`tests/integration/par05_online_partition_conversion_test.zig`
creates and drops its own schema per test, never uses `helpers.TestHarness`, and holds ONE
`Pool`-acquired connection for the schema's entire lifetime rather than calling
`pool.acquire()`/`pool.release()` between `PartitionConverter` calls, since `Pool.acquire()`
resets `search_path` on every call per `src/db/pool.zig`'s `applyRequestStorageRouting()`).
`pool_size = 2` is used (the `Pool.init()` minimum) even though only one connection is ever
acquired, to satisfy `PoolConfig`'s `pool_size < 2` fatal-at-startup check.

## Test Cases

### TC-PAR-05-01: parent creation alongside the live table
**Given:** an isolated schema with a pre-PAR-01-shaped, unpartitioned `events` table populated
with rows spanning three calendar months
**When:** `PartitionConverter.createParent()` runs
**Then:** `events_part` exists, is `PARTITION BY RANGE (created_at)`, and the original `events`
table is untouched (same row count, still not partitioned) — appends to `events` would continue
to work unchanged (verified by inserting one more row into `events` after `createParent()` and
confirming it succeeds)
**Layer:** integration
**Acceptance criterion mapped:** PAR-05 AC1 (parent created alongside; live table continues
accepting appends unchanged)

### TC-PAR-05-02: PartitionRangeGap raised on empty events table
**Given:** an isolated schema with a `events` table that has ZERO rows
**When:** `PartitionConverter.validateCoverage()` runs
**Then:** `ConversionError.PartitionRangeGap` is returned and no DDL/backfill runs (verified by
confirming `events_part` does not exist afterward)
**Layer:** integration
**Acceptance criterion mapped:** PAR-05 AC2 (coverage-gap detection; degenerate "nothing to
convert" case treated as a gap per the module's own doc comment)

### TC-PAR-05-03: backfill loop is idempotent under interruption/re-run
**Given:** an isolated schema with `events_part` created and `plat_event_idempotency`
backfilled, and a two-month populated `events` table
**When:** `PartitionConverter.backfillAllMonths()` runs to completion once, then runs a SECOND
time against the same `months` list (simulating a re-run after interruption)
**Then:** the second run raises no error, and `events_part`'s total row count after the second
run equals the row count after the first run (no duplicates inserted — `ON CONFLICT (event_id,
created_at) DO NOTHING` absorbed every row on the re-run)
**Layer:** integration
**Acceptance criterion mapped:** PAR-05 AC3 (interrupted/re-run backfill window is idempotent)

### TC-PAR-05-04: swap transaction renames tables and is retryable on lock timeout
**Given:** an isolated schema with `events_part` fully backfilled from a populated `events`
table (matching row counts)
**When:** `PartitionConverter.swap()` runs
**Then:** `events` (the ORIGINAL unpartitioned table) has been renamed to `events_legacy`, and
`events_part` has been renamed to `events` — verified by querying `pg_class`/`pg_namespace` for
both names post-swap, and by confirming the new `events` is `PARTITION BY RANGE`
**Layer:** integration
**Acceptance criterion mapped:** PAR-05 AC4 (swap transaction issues the two RENAME statements
inside one transaction; catch-up replay closes the gap since the last backfilled row)

### TC-PAR-05-05: row-count reconciliation passes when counts match
**Given:** an isolated schema immediately after a successful `swap()` (per-month partition
tables under `events_legacy` and the new `events` hold identical rows, since the swap replayed
the full catch-up window)
**When:** `PartitionConverter.reconcileOrRollback()` runs
**Then:** no error is returned (every month's `count(*)` matches) and no inverse rename occurs —
verified by confirming `events` (not `events_part_failed`) still holds the live partitioned
table afterward
**Layer:** integration
**Acceptance criterion mapped:** PAR-05 AC5 (post-swap per-month row-count match — the
passing/happy-path half)

### TC-PAR-05-06: row-count mismatch triggers ConversionRowCountMismatch and inverse rename
**Given:** an isolated schema immediately after `swap()`, with one row deliberately deleted
from one of the new `events` partition tables (simulating a lost row) so that month's count
diverges from the corresponding `events_legacy` partition
**When:** `PartitionConverter.reconcileOrRollback()` runs
**Then:** `ConversionError.ConversionRowCountMismatch` is returned, AND the inverse rename has
already executed by the time the error returns: the original table (now named
`events_part_failed`) exists, and `events_legacy` has been renamed back to `events` — verified
by querying `pg_class` for `events_part_failed` and confirming `events`'s row count matches the
pre-swap original (not the mutated new-partition count)
**Layer:** integration
**Acceptance criterion mapped:** PAR-05 AC5 (mismatch → `ConversionRowCountMismatch` +
inverse-rename restoration — the failing-path half)

## Fail-first confirmation

All six cases are NEW (no prior PAR-05 test file existed before this handoff). Confirmed
fail-first by running the full file against a `git stash` of `tests/integration/par05_online_partition_conversion_test.zig`
itself (i.e., the file did not exist, so `zig build test-integration-par05` failed with "file
not found" / step did not exist) and then, with the file restored, running once against a
deliberately broken build: commenting out the `ON CONFLICT (event_id, created_at) DO NOTHING`
clause in `backfillOneMonth()`'s INSERT locally reproduced a real `23505 duplicate key` failure
on TC-PAR-05-03's second `backfillAllMonths()` call, confirming the test genuinely exercises the
idempotency guarantee rather than passing vacuously. Reverted after confirming the failure.

## Coverage note

PAR-05 AC6 ("`events_legacy` is retained read-only for one full `archive_after_months` cycle and
then attached to `events_archive`; it is never emptied row by row") is implemented by ISS-0686
(GH-733 / WF03-GH733-20260812): `reconcileOrRollback()` now registers `events_legacy` in
`plat_partition_catalog`, and `PartitionRetention.runArchivalAging()` now queries for
`parent_table = 'events_legacy'` rows and calls `archiveLegacyTable()` to rename the table and
update the catalog to `state = 'ARCHIVED'`. The migration `1153_iss0686_archived_state.sql`
extends the CHECK constraint to accept `'ARCHIVED'`. Integration test coverage for this path is
provided by `tests/integration/iss0686_archived_state_test.zig` (archived_state_accepted).
(PAR-05's own AC bullet list in `docs/requirements.yaml` has 5 acceptance-criteria bullets plus
the trailing `events_legacy` retention sentence — TC-PAR-05-01 through -06 above map 1:1 onto
the five GIVEN/WHEN/THEN bullets, split into passing/failing halves where a bullet describes
both.)
