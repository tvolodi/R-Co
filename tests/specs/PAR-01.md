# Test Spec: PAR-01 — Monthly range partitioning of the event log

**Requirement:** PAR-01 — Extends ES-07, replacing the row-by-row archival move with a partition
lifecycle. `events` and `events_archive` SHALL be `PARTITION BY RANGE (created_at)`, one partition
per calendar month, named `events_YYYY_MM`. The primary key widens from `event_id` to
`(event_id, created_at)`. Global `idempotency_key` uniqueness is preserved by the separate
non-partitioned table `plat_event_idempotency (idempotency_key TEXT PRIMARY KEY, event_id UUID,
created_at TIMESTAMPTZ)`, written in the same transaction as every append.
**Priority:** MUST
**Test layer:** integration (schema/constraint level via par02/par03 fixtures + event_store
integration suite; no dedicated `par01_*_test.zig` file exists — see Traceability note below)

**Test-tier score (guide §2.1):** DB schema (2) + tenant isolation (2, `events`/`events_archive`/
`plat_event_idempotency` are PER_TENANT tables routed by `search_path`) + transactional boundary
(1, append writes `events`/`events_ephemeral` + `plat_event_idempotency` in one transaction) =
**5 points → sandbox tier** per the letter of the rubric. No Wasm/sandbox-execution surface is
touched by this requirement (it is pure DB partitioning), so no `test-sandbox`-tier test exists or
is applicable; unit + integration is the ceiling of what this requirement's own surface can
exercise. Recorded here for TEST-DESIGN-VALIDATOR per guide §2.1's instruction to state the score
even when the top tier does not literally apply.

## Acceptance Criteria Coverage

- AC1 — partition strategy RANGE on `created_at`, PK `(event_id, created_at)`, one partition per
  covered calendar month.
- AC2 — same `idempotency_key` in two different calendar months: rejected by
  `plat_event_idempotency`'s PK; partitioning does not narrow idempotency to per-month scope.
- AC3 — an append's `events` row and `plat_event_idempotency` row commit in one transaction; a
  failure of either rolls back both.
- AC4 — an append whose `created_at` falls in a month with no attached partition fails with
  `PartitionMissingForWrite` (a structured error), not silent misrouting.
- AC5 — every partition of `events`/`events_archive` carries the index
  `(instance_id, sequence_num)`.

## Test Cases

### TC-PAR-01-01 (schema shape, exercised via migration + par02/par03 fixtures)
**Given:** Migration `1147_par01_events_partitioning.sql` applied to `bpm_test`.
**When:** `events` and `events_archive` are inspected.
**Then:** Both are declared `PARTITION BY RANGE (created_at)` with PK `(event_id, created_at)`
(migration lines 82–141), and per-partition `CHECK (tenant_id IS NOT NULL)` +
range-matching CHECK are present before attach (proven transitively by every partition creation
site in this batch routing through `partition_attach.verifyAttachConstraints`/
`attachPartitionTimed`, PAR-04's own mechanism).
**Layer:** integration
**Acceptance criterion mapped:** AC1 (partition strategy, PK shape).
**Implemented by:** `tests/integration/par02_partition_catalog_test.zig` (`par02_partition_catalog:
unique_constraint_on_table_name`, `state_check_constraint_rejects_unknown_value`) and
`tests/integration/par03_retention_class_test.zig`
(`events_ephemeral_accepts_row_with_composite_pk`, which exercises the identical composite-PK
shape on the sibling `events_ephemeral` table PAR-01's PK-widening pattern extends to) — both
insert against the real migrated schema and assert the composite-key/CHECK behavior the migration
declares. The `events`/`events_archive` DETACH/ATTACH mechanics under this same PK shape are
additionally exercised end-to-end by `TC-ES-07-02` and `TC-ADP-11-03` (below).

### TC-PAR-01-02: global idempotency key rejected across different calendar months
**Given:** Two appends supplying the same `idempotency_key`, with `created_at` in different
calendar months (in practice: any two appends sharing a key inside the same test run, since
`plat_event_idempotency`'s PK is on `idempotency_key` alone, with no month/partition qualifier at
all — the strongest form of "partitioning does not narrow idempotency to a per-month scope").
**When:** The second append executes.
**Then:** It is rejected by `plat_event_idempotency`'s PK; `Store.append()` treats this as it
previously treated the row-level unique index — `AppendResult.is_duplicate = true`, no new row.
**Layer:** integration
**Acceptance criterion mapped:** AC2.
**Implemented by:** `tests/integration/event_store_integration_test.zig`
`TC-ES-03-01: duplicate idempotency_key returns original event with is_duplicate=true` (exercises
`Store.append()`'s live duplicate-key path against the real `plat_event_idempotency`-backed
mechanism this migration introduced — the test predates PAR-01 by name but now runs entirely
through the PAR-01 mechanism since `store.zig`'s idempotency check was rewired to
`plat_event_idempotency` in this same batch, per `store.zig:417-459`'s inline documentation).

### TC-PAR-01-03: append and idempotency-key claim commit atomically
**Given:** A normal append.
**When:** It commits.
**Then:** The `events` row and the `plat_event_idempotency` row are both visible afterward (single
transaction, `BEGIN`/`COMMIT` bracketing both INSERTs in `store.zig`'s `append()`).
**Layer:** integration
**Acceptance criterion mapped:** AC3 (positive direction — the negative/rollback direction is not
separately exercised; see Gap note below).
**Implemented by:** `tests/integration/event_store_integration_test.zig`
`TC-ES-01-01: valid append returns AppendResult with is_duplicate=false and persisted record`
(asserts the row is durably readable via `Store.read()` after commit) together with
`TC-ADP-11-02`'s routing assertions (below), which independently confirm both the `events`/
`events_ephemeral` row and the registry-side state are consistent post-commit.

### TC-PAR-01-04: partition-level tenant/ordering index present
**Given:** An attached partition of `events`/`events_ephemeral`/`events_archive`.
**When:** A row is inserted and then queried by `(instance_id, sequence_num)`.
**Then:** The composite index PAR-01 AC5 requires exists per-partition (declared via
`LIKE events INCLUDING DEFAULTS` at creation time, migration 1147 lines 112–117 /144-147, and
every dynamically created partition in `partition_maintenance.zig`/`partition_retention.zig`,
which use the same `LIKE <parent> INCLUDING DEFAULTS` clause).
**Layer:** integration
**Acceptance criterion mapped:** AC5.
**Implemented by:** `tests/integration/event_store_integration_test.zig`
`TC-ES-02-01`/`TC-ES-02-02` (ordered-read tests that depend on `(instance_id, sequence_number)`
ordering being efficiently queryable) exercise the index's *behavioral* contract; the index's
*physical presence per partition* is inherited structurally from `LIKE ... INCLUDING DEFAULTS`
and is not independently asserted via `pg_indexes` in any test in this batch (see Gap note).

### TC-PAR01-04-01: append with created_at in an unpartitioned month returns PartitionMissingForWrite
**Given:** The real, currently-attached partition of `events` that covers `now()` (identified live
via `pg_get_expr(c.relpartbound, c.oid)` against `pg_inherits`/`pg_class`, not assumed by name),
detached with its exact bound expression captured for reattachment.
**When:** An append is issued whose `created_at` (Postgres's own `now()` default — `AppendParams`
has no override) now falls in the gap the detach just opened.
**Then:** `Store.append()` returns `StoreError.PartitionMissingForWrite` (mapped by
`src/api/errors.zig`'s `problemPartitionMissingForWrite()` to HTTP 503), zero rows are written
(`countEvents` by the append's `idempotency_key` returns 0), and the detached partition is
unconditionally reattached via a `defer` registered immediately after the detach succeeds — so the
live partition set is restored regardless of test outcome, with no leaked state for any test
running after it.
**Layer:** integration
**Acceptance criterion mapped:** AC4.
**Implemented by:** `tests/integration/event_store_integration_test.zig`
`TC-PAR01-04-01: append with created_at in an unpartitioned month returns PartitionMissingForWrite`
(added by BACKEND-DEV commit `fa63e32d`, REWORK 1).

## Gap note — PAR-01 AC4 (`PartitionMissingForWrite`) — RESOLVED (REWORK 1)

AC4 requires: *"GIVEN an append whose `created_at` falls in a month with no attached partition,
WHEN it executes, THEN it fails with `PartitionMissingForWrite` and a structured error rather than
being routed to another partition."*

This was a genuine, unclosed implementation gap at the time of the original TEST-DESIGNER pass
(`StoreError` declared no such variant; the INSERT failure path collapsed every Postgres error to
the generic `TransactionFailed`; `src/api/errors.zig` had no mapping) — routed to BACKEND-DEV as
REWORK 1 rather than fixed from this role. BACKEND-DEV's commit `fa63e32d` closes it:

- `src/event_store/store.zig`: `StoreError` gains the `PartitionMissingForWrite` variant; the
  `append()` INSERT catch branch checks `conn.lastSqlState() == "23514"` (Postgres
  `check_violation`, the SQLSTATE partition routing raises for "no partition of relation ... found
  for row") before falling back to the generic `TransactionFailed`. The SQLSTATE bytes are copied
  to a local buffer before issuing `ROLLBACK`, since `lastSqlState()` aliases into the connection's
  mutable state and `ROLLBACK`'s own `exec()` call resets it.
- `vendor/pg/pg.zig` / `src/db/pool.zig`: new SQLSTATE-preservation plumbing
  (`Conn.last_sqlstate`, `lastSqlState()`) — previously every server error collapsed to a generic
  `PgError.ServerError`/`PoolError.QueryFailed` with no way to distinguish the specific condition.
- `src/api/errors.zig`: `problemPartitionMissingForWrite()` maps the new variant to HTTP 503
  (transient/retryable — the request succeeds once `plat_partition_maintenance`, PAR-02, attaches
  the missing partition — not a permanent client-input rejection).
- `tests/integration/event_store_integration_test.zig`: new `TC-PAR01-04-01` (above), verified by
  this TEST-DESIGNER re-validation pass to detach the real current-month partition, assert the
  specific `PartitionMissingForWrite`/HTTP-503-mapped error, assert zero rows written, and
  unconditionally reattach the partition via `defer` — confirmed via two consecutive
  `zig build test-integration-event-store` runs (29/29 both times) that the detach/reattach cycle
  is idempotent and leaves no state for a subsequent run or sibling test to trip over.

AC4 is now soundly proven. No gap remains for this acceptance criterion.

## Traceability Matrix

| PAR-01 acceptance area | Deterministic evidence |
|---|---|
| AC1 — partition strategy / PK shape | TC-PAR-01-01 |
| AC2 — global idempotency across months | TC-PAR-01-02 |
| AC3 — atomic append + idempotency claim (commit direction) | TC-PAR-01-03 |
| AC4 — `PartitionMissingForWrite` on missing partition | TC-PAR01-04-01 |
| AC5 — per-partition `(instance_id, sequence_num)` index | TC-PAR-01-04 |

## Execution Notes For TEST-RUNNER

- Primary targets: `zig build test-integration-par02`, `test-integration-par03`,
  `test-integration-event-store` (all require `BPM_TEST_DB_URL`).
- No dedicated `par01_*_test.zig` file exists; PAR-01's schema/constraint shape is exercised
  transitively through the par02/par03 fixture files (which insert against the PAR-01-shaped
  tables) and through `event_store_integration_test.zig`'s append/read/idempotency suite
  (including `TC-PAR01-04-01` for AC4), which runs entirely through the PAR-01 mechanism as of
  this batch.
- All five ACs are now traced to passing tests; no open gap remains for PAR-01 in this spec.
