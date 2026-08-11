# Test Spec: MIG-01 — Platform migration control table

**Requirement:** MIG-01 — The platform SHALL record platform migration state in a single
cross-tenant control table `platform.platform_migrations`, holding one row per
`(migration_id, tenant_id)` with `status` in `pending`, `done`, `failed`, plus `error_msg`,
`completed_at` and `run_id`. The table carries `UNIQUE (migration_id, tenant_id)` as the
upsert anchor and the partial index `platform_migrations_resume_idx ON (migration_id,
status) WHERE status IN ('pending','failed')` covering the resume query.

**Priority:** MUST
**Test layer:** integration (real PostgreSQL via `helpers.TestHarness` and, for the seeding
case, a real `bpm.pool.Pool` through `runFanout`)
**Test-tier score (test_developer_guide.md §2.1):** DB schema (2, new table/constraints/index)
+ tenant isolation (2, keyed by `tenant_id`, one row per tenant) = **4 points → sandbox
tier** per the rubric's own worked example 1 (a migration adding constraints to a
tenant-scoped-keyed table). No Wasm/sandbox-execution surface exists in this table, so no
sandbox-layer test applies in practice; unit + integration is the layer this requirement's
actual content needs, and that is what is provided below.
**Design:** `src/design/mig-02-mig-03-platform-migration-fanout.md` (MIG-01's own migration,
`migrations/1144_platform_migrations_control_table.sql`, is Type C with no dedicated design
doc per the migration's own header comment — "Type C, not Type E" per
`templates/lego-catalog.md`'s selection rules)
**Implementation:** `migrations/1144_platform_migrations_control_table.sql`

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN a fanout begins, WHEN the control rows are seeded, THEN exactly one row exists per enabled tenant at `status = 'pending'`, keyed by `(migration_id, tenant_id)`. | `TC-MIG-01-AC1-fanout` (new — see Coverage gap below) |
| AC2 | GIVEN the table is created, WHEN its constraints are inspected, THEN `UNIQUE (migration_id, tenant_id)` exists and `status` is constrained by a CHECK over exactly `pending`, `done`, `failed`. | `unique_constraint_on_migration_tenant_pair`, `status_check_constraint_rejects_unknown_value` |
| AC3 | GIVEN the resume query runs, WHEN its plan is inspected, THEN it uses `platform_migrations_resume_idx`. | `resume_index_used_by_pending_or_failed_query` |
| AC4 | GIVEN a tenant fails, WHEN its row is written, THEN `error_msg` carries the SQLSTATE and the message text and `completed_at` is null. | `failed_row_carries_error_msg_and_null_completed_at` |
| AC5 | GIVEN a tenant succeeds, WHEN its row is written, THEN `completed_at` is set and `error_msg` is null. | `done_row_carries_completed_at_and_null_error_msg` |

---

## Coverage gap found and closed

`tests/integration/platform_migrations_control_table_test.zig` (BACKEND-DEV's original 5
tests) directly inserts rows with an already-chosen terminal status (`'pending'`, `'failed'`,
`'done'`) to test the table's static shape — its UNIQUE anchor, CHECK constraint, and resume
index. None of those 5 tests exercise the actual **seeding** behavior AC1 describes: "GIVEN
a fanout begins, WHEN the control rows are seeded, THEN exactly one row exists per enabled
tenant at status = 'pending'". That behavior lives in
`src/platform/migration_fanout.zig::seedPendingRow`, called from `runFanout`'s seed loop —
code this control-table test file has no path to exercise, since it only ever opens a raw
`TestHarness` connection and writes rows itself.

Every test in `tests/integration/migration_fanout_test.zig` (the MIG-02/MIG-03 file) that
calls `runFanout` also implicitly exercises seeding, but every one of them only inspects the
control row **after** `runFanout` returns — by which point every row has already transitioned
to `done` or `failed` (per `applyToTenant`'s `markDone`/`recordFailureSeparately`). No
existing test observed the row in its seeded, still-`pending` state, so AC1's specific claim
("exactly one row... at status = 'pending', keyed by (migration_id, tenant_id)") was
asserted only by inference, never directly.

**Closed by:** a new test case, `TC-MIG-01-AC1-fanout`, added to
`tests/integration/migration_fanout_test.zig` (not duplicated into the control-table file,
since the seeding code path only exists inside `runFanout`). It uses a purpose-built
`DdlStep` (`seedCheckingFailingStep`) that runs **inside** `applyToTenant`'s per-tenant
transaction — i.e. strictly after the seed loop has already inserted rows for every
snapshot tenant, and strictly before `markDone`/`recordFailureSeparately` can touch this
tenant's row (both run only after `step()` returns). The step queries its own tenant's
control row via the same `conn` it was handed, asserts exactly one row exists with
`status = 'pending'` and `completed_at IS NULL`, then deliberately fails so the row's
terminal state (`failed`, with `error_msg = "SimulatedDdlFailure"`) is separately verifiable
by the outer test — proving the in-step assertion actually ran and passed, since a failed
in-step assertion would have produced a *different* `error_msg` (see `tenantIdFromSchemaName`
and `seedCheckingFailingStep` in the same file for how tenant identity is recovered from
`schema_name` without introducing module-level shared state, which
`tools/lint_test_isolation.py`'s T020 check forbids in this file).

**Fail-first confirmation:** verified live by temporarily changing
`seedPendingRow`'s SQL literal from `'pending'` to `'done'` in
`src/platform/migration_fanout.zig`, rebuilding, and re-running
`zig build test-integration-mig02-mig03`: the new test failed with
`TestExpectedPendingStatus` (the in-step assertion catching the wrong seeded status) while
the other 7 tests in the file continued to pass. The change was then reverted and the full
target re-run to confirm 8/8 passing again. This is not a hypothetical — it was executed.

---

## Test cases

### TC-MIG-01-AC2a: UNIQUE (migration_id, tenant_id) rejects a duplicate pair
**Given:** A control row already inserted for a random `(migration_id, tenant_id)` pair.
**When:** A second INSERT is attempted for the identical pair.
**Then:** PostgreSQL raises `error.ServerError` (23505 unique_violation on
`platform_migrations_migration_tenant_uq`); exactly one row exists for the pair afterward.
**Layer:** integration
**Acceptance criterion mapped:** AC2 (UNIQUE half)
**Zig test:** `"platform_migrations_control_table: unique_constraint_on_migration_tenant_pair"` (`tests/integration/platform_migrations_control_table_test.zig`)

### TC-MIG-01-AC2b: CHECK constraint rejects a status outside pending/done/failed
**Given:** A fresh `(migration_id, tenant_id)` pair.
**When:** An INSERT with `status = 'bogus'` is attempted.
**Then:** PostgreSQL raises `error.ServerError` (23514 check_violation); no row is inserted (count = 0 afterward).
**Layer:** integration
**Acceptance criterion mapped:** AC2 (CHECK half)
**Zig test:** `"platform_migrations_control_table: status_check_constraint_rejects_unknown_value"`

### TC-MIG-01-AC3: resume query is served by platform_migrations_resume_idx
**Given:** A `pending` row for a random `(migration_id, tenant_id)` pair; `enable_seqscan` forced off for the query to make index usage deterministic rather than cost-based.
**When:** `EXPLAIN SELECT * FROM platform.platform_migrations WHERE migration_id = $1 AND status IN ('pending', 'failed')` is run.
**Then:** The plan text contains `platform_migrations_resume_idx`.
**Layer:** integration
**Acceptance criterion mapped:** AC3
**Zig test:** `"platform_migrations_control_table: resume_index_used_by_pending_or_failed_query"`

### TC-MIG-01-AC4: failed row carries error_msg and null completed_at
**Given:** A row inserted directly with `status = 'failed'`, `error_msg = '23505: duplicate key value'`.
**When:** The row is read back.
**Then:** `status = 'failed'`, `error_msg` matches exactly, `completed_at IS NULL`.
**Layer:** integration
**Acceptance criterion mapped:** AC4
**Zig test:** `"platform_migrations_control_table: failed_row_carries_error_msg_and_null_completed_at"`

### TC-MIG-01-AC5: done row carries completed_at and null error_msg
**Given:** A row inserted directly with `status = 'done'`, `completed_at = now()`.
**When:** The row is read back.
**Then:** `status = 'done'`, `completed_at IS NOT NULL`, `error_msg IS NULL`.
**Layer:** integration
**Acceptance criterion mapped:** AC5
**Zig test:** `"platform_migrations_control_table: done_row_carries_completed_at_and_null_error_msg"`

### TC-MIG-01-AC1-fanout: control rows are seeded pending for every tenant before any step runs
**Given:** Two fixture ACTIVE tenants inserted into `public.tenant`; a fresh `migration_id`/`run_id` pair.
**When:** `runFanout` is called with `seedCheckingFailingStep`, a `DdlStep` that — for whichever tenant it is invoked for — queries its own tenant's `platform.platform_migrations` row via the same in-transaction `conn` it was given, asserts exactly one row exists with `status = 'pending'` and `completed_at IS NULL`, then deliberately raises.
**Then:** `runFanout` returns with `pending == 0` and `failed >= 2`; both fixture tenants' rows are `status = 'failed'` with `error_msg = "SimulatedDdlFailure"` (proving the in-step pending-state assertion ran and passed for both tenants — a failed assertion inside the step would have produced a different `error_msg`, catching a regression).
**Layer:** integration
**Acceptance criterion mapped:** AC1
**Zig test:** `"TC-MIG-01-AC1-fanout: control rows are seeded pending for every tenant before any step runs"` (`tests/integration/migration_fanout_test.zig` — new test added by TEST-DESIGNER)

---

## Fixtures and isolation

Every test uses either `helpers.TestHarness` (rolls back automatically, per-test-UUID
`tenant_id`/`migration_id`/`run_id` generated via `std.testing.io.random`, never a static
literal) or, for the fanout-seeding case, `bpm.pool.Pool` with autocommitted fixture
tenants inserted via `insertActiveTenant` and cleaned up via `defer cleanupTenant` /
`defer cleanupControlRows` — the established pattern in
`tests/integration/migration_fanout_test.zig`, matching every other test in that file.
`migration_id`/`run_id` values are randomized per test run (`randomToken` with an 8-byte
random suffix) so repeated runs against a long-lived `bpm_test` container never collide on
the UNIQUE anchor. No fixture state is shared across test blocks.

---

## Coverage summary

| Test case | Zig `test "..."` name | File | Covers |
|---|---|---|---|
| TC-MIG-01-AC2a | `platform_migrations_control_table: unique_constraint_on_migration_tenant_pair` | `platform_migrations_control_table_test.zig` | AC2 (UNIQUE) |
| TC-MIG-01-AC2b | `platform_migrations_control_table: status_check_constraint_rejects_unknown_value` | `platform_migrations_control_table_test.zig` | AC2 (CHECK) |
| TC-MIG-01-AC3 | `platform_migrations_control_table: resume_index_used_by_pending_or_failed_query` | `platform_migrations_control_table_test.zig` | AC3 |
| TC-MIG-01-AC4 | `platform_migrations_control_table: failed_row_carries_error_msg_and_null_completed_at` | `platform_migrations_control_table_test.zig` | AC4 |
| TC-MIG-01-AC5 | `platform_migrations_control_table: done_row_carries_completed_at_and_null_error_msg` | `platform_migrations_control_table_test.zig` | AC5 |
| TC-MIG-01-AC1-fanout | `TC-MIG-01-AC1-fanout: control rows are seeded pending for every tenant before any step runs` | `migration_fanout_test.zig` | AC1 |

**Implemented case count: 6 test blocks** across the two files (5 pre-existing +
1 added by TEST-DESIGNER to close the AC1 gap). All 5 acceptance criteria have direct
coverage. No `error.SkipZigTest` in either file (verified by grep — zero matches).

Run: `zig build test-integration-mig01` — 5/5 passing (unchanged by this batch — no test
added to this file). `zig build test-integration-mig02-mig03` — 8/8 passing (7 pre-existing
+ 1 new).

---

## Traceability

- MIG-01 acceptance: AC1 (via the new fanout-seeding test, MIG-02/MIG-03 file), AC2-AC5 (via
  the pre-existing control-table file).
- See MIG-02 (`tests/specs/MIG-02.md`) and MIG-03 (`tests/specs/MIG-03.md`) for the
  transactional-commit and fanout-loop requirements that read and write this table at
  runtime.
- See DDL-05 (`tests/specs/DDL-05.md`) — unrelated namespace rule; noted only because both
  requirements' migrations landed in the same batch.
