# Test Spec: DDL-04 — Idempotent batched backfill

**Requirement:** DDL-04 — The backfill phase SHALL be idempotent and batched. The generated
statement is `UPDATE t SET c = <expr> WHERE c IS NULL AND ctid = ANY (ARRAY(SELECT ctid FROM t
WHERE c IS NULL LIMIT $1))`, executed in a loop with one transaction per batch until an
iteration reports zero updated rows. The loop SHALL NOT run inside an outer transaction.
`backfill_batch_size` defaults to 5000 rows with an upper bound of 50000. A generated backfill
whose predicate is not bounded by `IS NULL` SHALL be rejected with `NonIdempotentBackfill`.

**Priority:** MUST
**Test layer:** unit (`validateGeneratedBackfill` pure guard) + integration (real `runBackfill`
loop against real PostgreSQL tables)
**Test-tier score (test_developer_guide.md §2.1):** DB schema (2, migration 1163 creates
`plat_migration_state`) + transactional boundary (1, the loop owns per-batch transactions and
never runs inside an outer transaction) = **3 points → sandbox tier by the rubric's raw score**
— same note as `tests/specs/ORD-01.md`: no Wasm/sandbox surface exists for this platform-DDL
family, so unit + integration against real Postgres is the proportionate ceiling.
**Design:** `src/design/ddl-04-idempotent-batched-backfill.md`
**Implementation:** `src/platform/backfill.zig` (`validateGeneratedBackfill`, `runBackfill`,
`recordBatchProgress`), migration `1163_ddl04_plat_migration_state.sql`

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN a backfill is interrupted after 40 of 100 batches and the migration runner restarts, WHEN the migration is re-run, THEN it resumes against the same `c IS NULL` predicate, rows already backfilled are skipped, and the end state is identical to an uninterrupted run. | `TC-DDL-04-AC1-full-run-then-rerun` (identical end state) + `TC-DDL-04-AC1-resume-partial` (resumes from a seeded RUNNING row + partially-backfilled table) |
| AC2 | GIVEN a generated backfill whose predicate is not bounded by `IS NULL`, WHEN validated, THEN `NonIdempotentBackfill` is returned and no statement is executed. | `backfill: validateGeneratedBackfill accepts an IS NULL-bounded batch` / `rejects a non-IS-NULL predicate` / `rejects a non-batched statement` (module unit tests, `src/platform/backfill.zig`) — pure guard, no DB |
| AC3 | GIVEN a backfill batch, WHEN it executes, THEN it holds `ROW EXCLUSIVE` on the table and commits before the next batch begins; no transaction spans two batches. | `TC-DDL-04-AC3-per-batch-commit-durable` (every batch committed; no outer transaction) |
| AC4 | GIVEN a batch exceeds 5 s, WHEN the next batch is planned, THEN `backfill_batch_size` is halved for that tenant with a floor of 500 rows. | `TC-DDL-04-AC4-halving` (config `batch_timeout_ms` forced below real batch latency → `final_batch_size` halved) |
| AC5 | GIVEN ten consecutive iterations report no progress, WHEN the loop detects the stall, THEN it stops and escalates with the remaining `IS NULL` row count for each tenant. | `TC-DDL-04-AC5-stall-escalation` (stuck table: 0 rows updated but rows remain → `stalled = true` after threshold) |
| AC6 | Rows updated per batch and remaining `IS NULL` rows per tenant are recorded in `plat_migration_state`. | `ddl04_plat_migration_state: progress_recording_updates_counters_in_place` (schema test) + `TC-DDL-04-AC6-loop-records-progress` (real loop writes cumulative counters) + `TC-DDL-04-AC6b-persists-halved-batch-size` (adaptive batch_size persisted; distinguishes pre-fix from post-fix) |

---

## Test cases

### TC-DDL-04-AC1-full-run-then-rerun: a completed backfill re-run updates 0 rows and ends identically
**Given:** A tenant table `t` with `N` rows where `c IS NULL`, a `GeneratedBackfill` bounded by
`IS NULL` with a `ctid = ANY (... LIMIT $1)` subquery, and a `runBackfill` on a real pool.
**When:** `runBackfill` runs to completion (loop ends at 0 updated rows), then `runBackfill`
runs again on the same table.
**Then:** The first run updates `N` rows (`rows_updated_total == N`, `rows_remaining == 0`,
`status == applied`, `stalled == false`); the second run updates `0` rows and terminates
immediately (`rows_updated_total == 0`, `rows_remaining == 0`, `batches_run == 1`) — the end
state is identical, proving the `IS NULL` predicate is the resume source of truth.
**Layer:** integration
**Acceptance criterion mapped:** AC1
**Zig test:** `TC-DDL-04-AC1-full-run-then-rerun` (`tests/integration/ddl04_backfill_loop_test.zig`)

### TC-DDL-04-AC1-resume-partial: an interrupted run resumes against `IS NULL`, skipping backfilled rows
**Given:** A table with `N` rows, of which `M < N` have already been backfilled (c not null) and
`N - M` remain `IS NULL`; a `plat_migration_state` row for `(migration_id, tenant, 'backfill')`
in `RUNNING` with `rows_updated_total = M` (the interrupt record).
**When:** `runBackfill` runs for that migration/tenant.
**Then:** It skips the already-backfilled rows (predicate `c IS NULL`) and updates exactly
`N - M` rows; `rows_updated_total` reflects only the resumed batch(es); the final `rows_remaining`
is `0`; end state equals an uninterrupted run (all rows backfilled).
**Layer:** integration
**Acceptance criterion mapped:** AC1
**Zig test:** `TC-DDL-04-AC1-resume-partial` (`tests/integration/ddl04_backfill_loop_test.zig`)

### backfill: validateGeneratedBackfill accepts an IS NULL-bounded batch
**Given:** A `GeneratedBackfill` whose SQL is `UPDATE ... WHERE c IS NULL AND ctid = ANY (... LIMIT $1)`.
**When:** `validateGeneratedBackfill` is called with batch size 5000.
**Then:** Returns `5000` (no `NonIdempotentBackfill`).
**Layer:** unit
**Acceptance criterion mapped:** AC2 (positive case)
**Zig test:** `backfill: validateGeneratedBackfill accepts an IS NULL-bounded batch` (in `src/platform/backfill.zig`)

### backfill: validateGeneratedBackfill rejects a non-IS-NULL predicate
**Given:** A `GeneratedBackfill` whose predicate is `WHERE amount = 0` (not `IS NULL`-bounded).
**When:** `validateGeneratedBackfill` is called.
**Then:** Returns `error.NonIdempotentBackfill` and — because the guard runs before any connection
is opened — no statement is ever executed.
**Layer:** unit
**Acceptance criterion mapped:** AC2 (negative case)
**Zig test:** `backfill: validateGeneratedBackfill rejects a non-IS-NULL predicate` (in `src/platform/backfill.zig`)

### backfill: validateGeneratedBackfill rejects a non-batched statement
**Given:** A `GeneratedBackfill` without the `ctid = ANY` bounded-batch shape (e.g. a plain
`UPDATE ... WHERE c IS NULL`).
**When:** `validateGeneratedBackfill` is called.
**Then:** Returns `error.NonIdempotentBackfill` (unbounded statements cannot be batched safely).
**Layer:** unit
**Acceptance criterion mapped:** AC2 (batched-shape half)
**Zig test:** `backfill: validateGeneratedBackfill rejects a non-batched statement` (in `src/platform/backfill.zig`)

### TC-DDL-04-AC3-per-batch-commit-durable: every batch commits; no outer transaction spans batches
**Given:** A table with `N` rows needing backfill, `runBackfill` invoked with a plain `pool`
connection (no surrounding transaction).
**When:** `runBackfill` runs and returns.
**Then:** (a) the `plat_migration_state` progress row and the backfilled table rows are visible on a
FRESH connection with no explicit commit — i.e. each batch committed before the next began
(durability of per-batch commit, AC3's "commits before the next batch begins"); (b) `batches_run`
equals the number of batches implied by `ceil(N / batch_size)`, and no single batch's lock leaked
across iterations (the next batch's `UPDATE` never blocked on the previous batch's lock, proven by
the run completing).
**Layer:** integration
**Acceptance criterion mapped:** AC3
**Zig test:** `TC-DDL-04-AC3-per-batch-commit-durable` (`tests/integration/ddl04_backfill_loop_test.zig`)

### TC-DDL-04-AC4-halving: a batch over the timeout halves the next batch size
**Given:** A table with more rows than a single `backfill_batch_size` can drain (at least
`backfill_batch_size + 1` rows), and a config with `backfill_batch_size = 5000`,
`batch_timeout_ms = 1` (so any real batch exceeds the threshold) and `batch_size_floor = 500`.
**When:** `runBackfill` runs to completion.
**Then:** `final_batch_size` (the batch size used for the last batch) is `2500` — exactly
`5000 / 2` — proving the next-batch halving fired; the floor bound is respected (a second
halving would not go below 500).
**Layer:** integration
**Acceptance criterion mapped:** AC4
**Zig test:** `TC-DDL-04-AC4-halving` (`tests/integration/ddl04_backfill_loop_test.zig`)

### TC-DDL-04-AC5-stall-escalation: ten zero-progress iterations stop the loop and escalate with remaining count
**Given:** A table where the batch statement's WHERE can never match the remaining `IS NULL` rows
(a generated predicate with an extra unsatisfiable condition passes the `validateGeneratedBackfill`
guard because it still contains `IS NULL` and `ctid = ANY`), so every batch reports 0 updated rows
while `count(*) WHERE c IS NULL > 0`; config `stall_threshold_iterations = 2`.
**When:** `runBackfill` runs.
**Then:** The loop stops with `stalled == true`, `status == failed`, and `rows_remaining` carries
the remaining `IS NULL` count so the caller escalates — it does NOT terminate silently as if the
backfill were complete.
**Layer:** integration
**Acceptance criterion mapped:** AC5
**Zig test:** `TC-DDL-04-AC5-stall-escalation` (`tests/integration/ddl04_backfill_loop_test.zig`)
> ⚠️ This test is expected to FAIL against the current implementation: `runBackfill` executes
> `if (rows_updated == 0) break;` BEFORE the AC5 stall check, so the stall branch is unreachable.
> A zero-progress-but-not-empty backfill terminates with `stalled == false` instead of escalating.
> Filed as an implementation defect (BLOCKER) in this handoff's `result.issues`.

### TC-DDL-04-AC6-loop-records-progress: the loop records cumulative counters into plat_migration_state
**Given:** A table with `N` rows needing backfill and a unique `(migration_id, tenant_schema,
'backfill')` key.
**When:** `runBackfill` runs to completion with the default config (`backfill_batch_size = 5000`).
**Then:** Exactly one `plat_migration_state` row exists for the key; `rows_updated_total == N`,
`rows_remaining == 0`, `last_batch_rows == 0` (the terminating zero-rows batch), `last_batch_ms >= 0`,
`status == 'applied'`, `backfill_batch_size == 5000` — and no second row was created by the upsert
across batches.
**Layer:** integration
**Acceptance criterion mapped:** AC6
**Zig test:** `TC-DDL-04-AC6-loop-records-progress` (`tests/integration/ddl04_backfill_loop_test.zig`)

### TC-DDL-04-AC6b-persists-halved-batch-size: plat_migration_state records the adaptive batch size, not the initial default
**Given:** A table with 6000 rows needing backfill, config `backfill_batch_size = 5000`,
`batch_timeout_ms = 1` (every real batch exceeds 1 ms) so halving fires on each non-empty batch.
**When:** `runBackfill` runs to completion (iter 1 uses size 5000 → halves to 2500; iter 2 uses
2500 → halves to 1250; iter 3 uses 1250, 0 updates, exits).
**Then:** `plat_migration_state.backfill_batch_size` for the key equals `1250` (the final adaptive
value) — **not** `5000` (the initial config default). This assertion distinguishes the pre-fix
state (where `recordBatchProgress` hardcoded 5000) from the post-fix state (where the live
`batch_size` is passed and persisted). `status` must also be `applied`.
**Layer:** integration
**Acceptance criterion mapped:** AC6 (ISS-0716 — adaptive backfill_batch_size persistence)
**Zig test:** `TC-DDL-04-AC6b-persists-halved-batch-size` (`tests/integration/ddl04_backfill_loop_test.zig`)

### ddl04_plat_migration_state: unique_constraint_on_migration_tenant_phase
**Given:** A `plat_migration_state` row for `(migration_id, tenant_schema, 'backfill')`.
**When:** A second INSERT for the same key is attempted.
**Then:** Fails with `error.ServerError` (SQLSTATE 23505 unique_violation on
`plat_migration_state_migration_tenant_phase_uq`) and exactly one row remains — the anchor the
loop's progress upsert relies on (AC6).
**Layer:** integration (schema contract)
**Acceptance criterion mapped:** AC6 (upsert anchor)
**Zig test:** `ddl04_plat_migration_state: unique_constraint_on_migration_tenant_phase` (`tests/integration/ddl04_plat_migration_state_test.zig`)

### ddl04_plat_migration_state: status_check_constraint_rejects_unknown_value
**Given:** A `plat_migration_state` INSERT with `status = 'bogus'`.
**When:** Executed.
**Then:** Fails with `error.ServerError` (SQLSTATE 23514) — status is limited to
pending/running/applied/failed.
**Layer:** integration (schema contract)
**Acceptance criterion mapped:** supports AC1's resume (RUNNING) / AC5's failed state
**Zig test:** `ddl04_plat_migration_state: status_check_constraint_rejects_unknown_value`

### ddl04_plat_migration_state: backfill_batch_size_check_bounds
**Given:** `backfill_batch_size` inserts at 100, 60000, 500, and 50000.
**When:** Executed.
**Then:** 100 and 60000 fail (SQLSTATE 23514); 500 (floor) and 50000 (ceiling) succeed — the AC4
floor/upper-bound are schema-enforced.
**Layer:** integration (schema contract)
**Acceptance criterion mapped:** AC4 (floor 500 / upper bound 50000)
**Zig test:** `ddl04_plat_migration_state: backfill_batch_size_check_bounds`

### ddl04_plat_migration_state: resume_reads_persisted_progress
**Given:** A seeded RUNNING row (rows_updated_total 200000, rows_remaining 50000).
**When:** The resume query (`status IN ('pending','running')`) runs via the partial resume index.
**Then:** The row is found with the persisted cumulative counters a resumed loop reads to skip
already-backfilled rows (AC1).
**Layer:** integration
**Acceptance criterion mapped:** AC1
**Zig test:** `ddl04_plat_migration_state: resume_reads_persisted_progress`

### ddl04_plat_migration_state: progress_recording_updates_counters_in_place
**Given:** A seeded RUNNING row; an in-place progress UPDATE (rows_updated_total + 5000,
rows_remaining 45000, last_batch_ms 900).
**When:** The row is re-read.
**Then:** Exactly one row remains with rows_updated_total 205000, rows_remaining 45000,
last_batch_rows 5000, last_batch_ms 900 — the AC6 in-place (no-second-row) progress shape.
**Layer:** integration
**Acceptance criterion mapped:** AC6
**Zig test:** `ddl04_plat_migration_state: progress_recording_updates_counters_in_place`

---

## Fixture isolation
All integration fixtures use per-test UUIDs (`bpm.uuid.newUuidV4`) for the migration_id and the
test table name, created via a real pool connection (committed) and removed in `defer` — the same
pattern as `tests/integration/ordering_consumer_test.zig`. No module-level mutable state; no
cross-test sharing.

---

## Run status (2026-08-16, `test-integration-ddl04-backfill`)
5/6 loop tests pass; 3/3 module unit tests pass; 5/5 schema tests pass. The single failure is
`TC-DDL-04-AC5-stall-escalation` — expected fail-first: `runBackfill` executes
`if (rows_updated == 0) break;` before the stall check, making the DDL-04 AC5 stall policy
unreachable. Reported as an implementation defect (BLOCKER) in the handoff. Also observed: the
`plat_migration_state.backfill_batch_size` column is hardcoded to 5000 by `recordBatchProgress`
(the live adaptive value is only reported via `BackfillResult.final_batch_size`) and the row's
`status` is left `'running'` after completion (the design's `applied`/`failed` terminal write is
missing) — both recorded as MINOR discrepancies.
