# Test Spec: MIG-03 — Tenant migration fanout with continue on failure

**Requirement:** MIG-03 — The platform SHALL apply a migration across a snapshot of enabled
tenants ordered by `tenant_id`, holding `pg_try_advisory_lock(hashtext(migration_id))` on the
platform database for the duration of the run. A failure in tenant N SHALL NOT prevent
tenants N+1 through M from being attempted; per-tenant errors are collected and the run
continues to the end of the snapshot.

**Priority:** MUST
**Test layer:** integration (real PostgreSQL via `bpm.pool.Pool` and `runFanout`, real
`pg_try_advisory_lock`, no mocks)
**Test-tier score (test_developer_guide.md §2.1):** Tenant isolation (2, snapshot ordered by
tenant, per-tenant outcome) + transactional boundary (1, the advisory lock's scope and the
per-tenant transaction loop) = **3 points → sandbox tier** per the rubric. As with MIG-01 and
MIG-02, this requirement has no Wasm/sandbox-execution surface; unit + integration covers its
actual content, consistent with the same reasoning documented in both sibling specs.
**Design:** `src/design/mig-02-mig-03-platform-migration-fanout.md`
**Implementation:** `src/platform/migration_fanout.zig` (`runFanout`, `acquireMigrationLock`)

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN tenant N fails, WHEN the run continues, THEN tenants N+1 through M are still attempted and each has a `done` or `failed` row when the run ends. | `TC-MIG-03-01`, `TC-MIG-03-01b` |
| AC2 | GIVEN the advisory lock for `migration_id` is already held, WHEN a second run is requested, THEN the platform returns HTTP 409 `MigrationAlreadyRunning`. | `TC-MIG-03-02` |
| AC3 | GIVEN two different `migration_id` values, WHEN both are run, THEN they may execute concurrently because the lock key is derived from `migration_id`. | `TC-MIG-03-03` |
| AC4 | GIVEN a tenant is created after the snapshot is taken, WHEN it is provisioned, THEN the tenant onboarding path applies the full migration set and inserts `done` rows, so the tenant is not left behind by the concurrent fanout. | Not tested — see Coverage note below (out of scope: the referenced onboarding path does not exist in this batch) |
| AC5 | GIVEN the snapshot is exhausted, WHEN the run returns, THEN the response carries `{run_id, done, failed, pending}` counts. | `TC-MIG-03-05` (plus every other test case in this file, which all read `result.done`/`.failed`/`.pending` as part of their own assertions) |

---

## Coverage note: AC4 (tenant-onboarding catch-up path)

AC4 describes a requirement on a **different** code path than the one this batch implements:
"the tenant onboarding path applies the full migration set and inserts `done` rows" refers to
the tenant-provisioning/onboarding flow (`src/identity/onboarding.zig` and similar), which
must be amended so that a tenant created mid-fanout is not left permanently un-migrated. This
batch's scope is `runFanout` itself (`src/platform/migration_fanout.zig`) — the design
artefact's own "Open Questions §2" section names this exact amendment as **not yet
implemented**, deferring it to when the onboarding path is next touched. `runFanout`'s
snapshot-once behavior is itself correctly implemented and is what makes AC4 necessary in
the first place (see `FanoutResult.pending`'s doc comment: "a tenant created after this
point has no pending row seeded for this migration_id and is never visited by this run's
loop... being caught up is the tenant-onboarding path's job, out of scope here").

No test exists for AC4 in this batch because the code AC4 describes does not exist yet —
this is the same class of documented, deliberate scope boundary as DDL-05's AC5 (see
`tests/specs/DDL-05.md`'s Scope note), not a coverage gap in code that does exist. When the
onboarding path is amended to apply the "full migration set" and insert `done` rows for a
newly created tenant, that change's own TEST-DESIGNER pass must add the AC4 test against
`src/identity/onboarding.zig` (or wherever the amendment lands) — it does not belong in this
file, since this file's `runFanout`-based tests have no way to exercise the onboarding code
path at all.

---

## Test cases

### TC-MIG-03-01: one tenant's DDL failure does not stop the fanout from reaching the others
**Given:** Three fixture ACTIVE tenants (A, B, C); `failingStep` applied uniformly (every tenant fails — simplest way to prove the loop visits all three despite failures, since Zig's plain `*const fn` `DdlStep` type cannot close over "fail only for tenant B", per the file's own header comment explaining this design choice).
**When:** A single `runFanout` call snapshots all three (plus any concurrently-running sibling test's own fixtures) and applies `failingStep`.
**Then:** `result.pending == 0`, `result.failed >= 3`; each of A, B, C has a `status = 'failed'` row — proving the loop reached every one of this test's fixture tenants, not just the first.
**Layer:** integration
**Acceptance criterion mapped:** AC1
**Zig test:** `"TC-MIG-03-01: one tenant's DDL failure does not stop the fanout from reaching the others"` (`tests/integration/migration_fanout_test.zig`)

### TC-MIG-03-01b: successful and failing runs against the same tenant set both reach every tenant
**Given:** Two fixture ACTIVE tenants (A, B); two separate `runFanout` calls under two different `migration_id`s — one with `succeedingStep`, one with `failingStep`.
**When:** Both runs execute against the same tenant set.
**Then:** The successful run yields `done >= 2` with both tenants' rows `done`; the failing run (different `migration_id`, independent control rows) yields `failed >= 2` with both tenants' rows `failed` — proving both positive and negative outcomes are independently reachable and neither starves the other.
**Layer:** integration
**Acceptance criterion mapped:** AC1 (positive companion — proves the loop's per-tenant independence works for successes too, not only for the uniform-failure case in TC-MIG-03-01)
**Zig test:** `"TC-MIG-03-01b: successful and failing runs against the same tenant set both reach every tenant"`

### TC-MIG-03-02: a second concurrent run for the same migration_id is refused with MigrationAlreadyRunning
**Given:** One fixture ACTIVE tenant; a `migration_id`'s advisory lock manually acquired on a dedicated connection (`SELECT pg_try_advisory_lock(hashtext($1))`), simulating an in-flight run holding the lock.
**When:** `runFanout` is called for the same `migration_id` while the lock is held.
**Then:** `runFanout` returns `error.MigrationAlreadyRunning`.
**Layer:** integration
**Acceptance criterion mapped:** AC2
**Zig test:** `"TC-MIG-03-02: a second concurrent run for the same migration_id is refused with MigrationAlreadyRunning"`
**Note on HTTP 409 mapping:** this test verifies the Zig-level `error.MigrationAlreadyRunning` return, which the design doc's Error taxonomy states the (not-yet-implemented) HTTP caller maps to 409 — the same division of labor as DDL-05's AC1 "the API responds 422" clause (see `tests/specs/DDL-05.md`). The HTTP-layer mapping itself has no route yet in this batch to test.

### TC-MIG-03-03: two different migration_ids do not contend on the advisory lock
**Given:** One fixture ACTIVE tenant; `migration_one`'s advisory lock held on a dedicated connection for the whole test (simulating an in-flight run).
**When:** `runFanout` is called for `migration_two` (a different `migration_id`) while `migration_one`'s lock is held.
**Then:** `migration_two`'s run succeeds normally (`pending == 0`, `done >= 1`, control row `done`) — proving the lock key is genuinely derived from `hashtext(migration_id)`, not a single global lock.
**Layer:** integration
**Acceptance criterion mapped:** AC3
**Zig test:** `"TC-MIG-03-03: two different migration_ids do not contend on the advisory lock"`

### TC-MIG-03-05: FanoutResult.run_id round-trips the caller-supplied run_id
**Given:** One fixture ACTIVE tenant; a caller-supplied `run_id` token.
**When:** `runFanout` is called and completes.
**Then:** `result.run_id` equals the exact caller-supplied `run_id` string; `result.pending == 0`.
**Layer:** integration
**Acceptance criterion mapped:** AC5 (the `run_id` field specifically — the `done`/`failed`/`pending` fields of the same struct are exercised by every other test case in this file, so this is the one field none of them separately confirm)
**Zig test:** `"TC-MIG-03-05: FanoutResult.run_id round-trips the caller-supplied run_id"`

---

## Fixtures and isolation

All tests use `bpm.pool.Pool` with fixture tenants inserted via `insertActiveTenant`
(autocommitted) and cleaned up via `defer cleanupTenant`, plus `defer cleanupControlRows` for
this test's control rows, keyed by random per-test `migration_id`/`run_id` tokens
(`randomToken`) — never static literals. Advisory-lock holder connections are released via
`defer pool.release(holder_conn)` and the lock itself via `defer holder_conn.exec("SELECT
pg_advisory_unlock(...)")`, so a test failure does not leave the lock held for a later test
or sibling binary. Per the file's own header comment, assertions target each test's own
fixture tenant rows by exact `(migration_id, tenant_id)` key, and use `>=` / invariant
checks on the returned counts (never exact equality against the full concurrent-binary
snapshot size), since `runFanout`'s tenant snapshot is the entire shared `public.tenant`
table, not scoped to any one test's fixtures — this is the real MIG-03 contract (a
system-wide snapshot), not a test artifact to work around.

---

## Coverage summary

| Test case | Zig `test "..."` name | Covers |
|---|---|---|
| TC-MIG-03-01 | `TC-MIG-03-01: one tenant's DDL failure does not stop the fanout from reaching the others` | AC1 |
| TC-MIG-03-01b | `TC-MIG-03-01b: successful and failing runs against the same tenant set both reach every tenant` | AC1 (positive companion) |
| TC-MIG-03-02 | `TC-MIG-03-02: a second concurrent run for the same migration_id is refused with MigrationAlreadyRunning` | AC2 |
| TC-MIG-03-03 | `TC-MIG-03-03: two different migration_ids do not contend on the advisory lock` | AC3 |
| TC-MIG-03-05 | `TC-MIG-03-05: FanoutResult.run_id round-trips the caller-supplied run_id` | AC5 |
| *(documented gap)* | — | AC4, out of scope this batch — the onboarding path it describes does not exist yet |

**Implemented case count: 5 test blocks** in `tests/integration/migration_fanout_test.zig`,
covering AC1, AC2, AC3, AC5 directly. AC4 is a documented, deliberate scope boundary (see
Coverage note above) matching the same pattern as DDL-05's AC5. No `error.SkipZigTest` in
this file (verified by grep — zero matches).

Run: `zig build test-integration-mig02-mig03` — 8/8 passing (includes MIG-02's 2 tests and
the new MIG-01 AC1 test in the same file; see `tests/specs/MIG-01.md` and
`tests/specs/MIG-02.md`).

---

## Traceability

- MIG-03 acceptance: AC1, AC2, AC3, AC5 directly tested; AC4 documented gap pending the
  tenant-onboarding path amendment (design doc's "Open Questions §2").
- See MIG-01 (`tests/specs/MIG-01.md`) for the control table's shape/constraint tests and the
  new seeding-behavior test this batch added.
- See MIG-02 (`tests/specs/MIG-02.md`) for the transactional-commit requirement sharing this
  same test file and the same `runFanout` entry point.
