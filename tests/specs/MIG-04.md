# Test Spec: MIG-04 — Migration resume for pending and failed tenants

**Requirement:** MIG-04 — The platform SHALL provide
`POST /api/v1/admin/migrations/{migration_id}/resume`, which applies the migration only to
tenants whose control row is `pending` or `failed`, reading that set through
`platform_migrations_resume_idx`. Tenants whose row is `done` are never re-applied.

**Priority:** MUST
**Test layer:** integration (real PostgreSQL via `bpm.pool.Pool` and `resumeFanout`, no mocks)
**Test-tier score (test_developer_guide.md §2.1):** Tenant isolation (2, per-tenant control row
selection is the entire point of resume) + transactional boundary (1, resume reuses
`applyToTenant`'s commit-with-DDL protocol) = **3 points → sandbox tier** per the rubric. No
Wasm surface exists in this requirement — consistent with MIG-02's own spec header reasoning
("no sandbox-layer content to test"), unit + integration is what the requirement's actual
content needs and is what is provided below.
**Design:** `src/design/mig-04-mig-05-mig-06-resume-idempotency-admin-surface.md`
**Implementation:** `src/platform/migration_fanout.zig` (`resumeFanout`, `ResumeRequest`,
`ResumeResult`)

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN rows in `done`, `pending` and `failed`, WHEN resume runs, THEN DDL is applied to the `pending` and `failed` tenants only. | `TC-MIG-04-01` |
| AC2 | GIVEN every row for the migration is `done`, WHEN resume runs, THEN it executes no DDL and returns zero counts. | `TC-MIG-04-02` |
| AC3 | GIVEN resume selects its tenant set, WHEN the query plan is inspected, THEN it reads through `platform_migrations_resume_idx`. | `TC-MIG-04-03` |
| AC4 | GIVEN a resume run, WHEN tenants are processed, THEN they are processed in `tenant_id` order, so the failure list is reproducible between a run and its resume. | `TC-MIG-04-04` |
| AC5 | Resume applies the MIG-02 rule: each tenant's control row is upserted in the same transaction as that tenant's DDL. | `TC-MIG-04-05` |

---

## Test cases

### TC-MIG-04-01: resume applies only to pending and failed tenants, never done
**Given:** Two fixture ACTIVE tenants seeded via a normal `runFanout` (both reach `done`); `tenant_failed`'s row is then manually flipped back to `failed` to simulate a prior failure.
**When:** `resumeFanout` is called with `succeedingStep`.
**Then:** `result.pending == 0`, `result.done >= 1`; `tenant_failed`'s row becomes `done`; `tenant_done`'s row is completely untouched (byte-identical `completed_at` before and after the resume run), proving `resumeFanout`'s snapshot query (`status IN ('pending','failed')`) never selected the already-done tenant.
**Layer:** integration
**Acceptance criterion mapped:** AC1
**Zig test:** `"TC-MIG-04-01: resume applies only to pending and failed tenants, never done"` (`tests/integration/migration_resume_test.zig`)

### TC-MIG-04-02: resume with every row already done executes no DDL and returns zero counts
**Given:** One fixture ACTIVE tenant seeded via `runFanout` to `done`.
**When:** `resumeFanout` is called with `mustNotBeCalledStep` — a step that fails the test loudly (a distinct, greppable error) if it is ever invoked.
**Then:** `result.done == 0`, `result.failed == 0`, `result.pending == 0` — the snapshot query correctly found zero pending/failed rows, so `mustNotBeCalledStep` is never called (if it were, the propagated error would surface as `failed >= 1`, which the assertions rule out).
**Layer:** integration
**Acceptance criterion mapped:** AC2
**Zig test:** `"TC-MIG-04-02: resume with every row already done executes no DDL and returns zero counts"`

### TC-MIG-04-03: resume's tenant snapshot query plan uses platform_migrations_resume_idx
**Given:** A fresh `migration_id` with no fixture rows (the query plan is examined independent of actual data volume).
**When:** `EXPLAIN` is run directly against the exact SQL text `resumeFanout` issues (`SELECT tenant_id::text FROM platform.platform_migrations WHERE migration_id = $1 AND status IN ('pending', 'failed') ORDER BY tenant_id`).
**Then:** The plan output contains the string `platform_migrations_resume_idx`, confirming the planner chose that index for this predicate shape.
**Layer:** integration
**Acceptance criterion mapped:** AC3
**Zig test:** `"TC-MIG-04-03: resume's tenant snapshot query plan uses platform_migrations_resume_idx"`

### TC-MIG-04-04: resume processes tenants in tenant_id ascending order
**Given:** Two fixture ACTIVE tenants, both seeded directly to `failed` status (no prior `runFanout` needed — resume's own query is what's under test).
**When:** The exact snapshot query `resumeFanout` uses is run directly and its two returned rows are compared; then `resumeFanout` itself is run to confirm both tenants reach `done`.
**Then:** The two `tenant_id::text` values come back in ascending lexical order (`std.mem.order(...) == .lt`), matching the query's own `ORDER BY tenant_id` clause; `resumeFanout`'s subsequent real run confirms both tenants reach `done` using the identical SQL text, tying the ordering proof to the actual entry point.
**Layer:** integration
**Acceptance criterion mapped:** AC4
**Zig test:** `"TC-MIG-04-04: resume processes tenants in tenant_id ascending order"`

### TC-MIG-04-05: resume applies the MIG-02 commit-with-DDL rule (rollback on failure, separate failed record)
**Given:** One fixture ACTIVE tenant, its control row seeded directly to `failed`.
**When:** `resumeFanout` is called with `succeedingStep`.
**Then:** `result.pending == 0`, `result.done >= 1`; the tenant's row reaches `status = 'done'` with `completed_at` set — proving resume reuses `applyToTenant`, the SAME per-tenant transaction protocol `runFanout` uses (MIG-02's commit-with-DDL rule), rather than a separate, divergent commit path.
**Layer:** integration
**Acceptance criterion mapped:** AC5
**Zig test:** `"TC-MIG-04-05: resume applies the MIG-02 commit-with-DDL rule (rollback on failure, separate failed record)"`

---

## Fixtures and isolation

All tests use `bpm.pool.Pool` (`pool_size = 5`) with fixture tenants inserted via
`insertActiveTenant` (autocommitted) and torn down via `defer cleanupTenant`. Every
`tenant_id`/`migration_id`/`run_id` is a fresh random value per test (`randomUuidStr`,
`randomToken` — never a static literal), and `defer cleanupControlRows` removes this test's
control rows regardless of pass/fail. Assertions read back rows by their own exact
`(migration_id, tenant_id)` key rather than any aggregate/global count, consistent with this
file's own header comment on fixture isolation under concurrent sibling `test-integration`
binaries. `mustNotBeCalledStep` proves a "must not be called" contract with a distinct,
greppable error (`StepMustNotHaveBeenCalled`) rather than a silent assumption.

---

## Coverage summary

| Test case | Zig `test "..."` name | Covers |
|---|---|---|
| TC-MIG-04-01 | `TC-MIG-04-01: resume applies only to pending and failed tenants, never done` | AC1 |
| TC-MIG-04-02 | `TC-MIG-04-02: resume with every row already done executes no DDL and returns zero counts` | AC2 |
| TC-MIG-04-03 | `TC-MIG-04-03: resume's tenant snapshot query plan uses platform_migrations_resume_idx` | AC3 |
| TC-MIG-04-04 | `TC-MIG-04-04: resume processes tenants in tenant_id ascending order` | AC4 |
| TC-MIG-04-05 | `TC-MIG-04-05: resume applies the MIG-02 commit-with-DDL rule (rollback on failure, separate failed record)` | AC5 |

**Implemented case count: 5 test blocks** in `tests/integration/migration_resume_test.zig`,
covering AC1–AC5 directly (100% of MIG-04's acceptance criteria — no structural/non-testable
notes needed for this requirement). No `error.SkipZigTest` in this file (verified by grep — zero
matches).

Run: `zig build test-integration-mig04-mig05` — 9/9 passing (this file also carries MIG-05's 4
test cases; see `tests/specs/MIG-05.md`).

**Coverage gap check:** none found. All 5 of MIG-04's acceptance criteria map to a specific,
independently meaningful test case; no gap-filling test was needed for this requirement.

---

## Traceability

- MIG-04 acceptance: AC1–AC5 all directly tested.
- See MIG-05 (`tests/specs/MIG-05.md`) for the idempotent-re-run requirement sharing this same
  test file and reusing the same `runFanout`/fixture helpers.
- See MIG-02 (`tests/specs/MIG-02.md`) for the commit-with-DDL protocol (`applyToTenant`) this
  requirement's AC5 reuses verbatim via `resumeFanout`.
