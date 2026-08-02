# Test Spec: ISS-0123 — DLQ rename + audit-trigger isolation regression

**Requirement:** ISS-0123 / GitHub tvolodi/R-Co#389 — `dead_letter_queue` legacy
table name and `bpm_test_fail_audit_insert` audit-trigger leak both regressed the
WF03-gh375-20260801 `test-runner-step5c` integration log. The fix has two
clusters:

- **Cluster B (C42703 / `column "source_ref" of relation "dead_letter_queue" does not exist`).**
  Production code and integration tests referenced the pre-rename name
  `dead_letter_queue`; the post-`072_tnt01_rename_legacy_tables.sql` canonical
  name is `dead_letter_items`. Drift between the two surfaces as a runtime
  C42703 from any tenant schema where migration 021 was not applied.
- **Cluster A (P0001 / `audit_entries is immutable` / `forced audit insert failure for test`).**
  `tests/integration/obs05_dlq_test.zig:TC-OBS-05-INT-03` deliberately installs
  the BEFORE-INSERT trigger `trg_bpm_test_fail_audit_insert` to verify the
  `handleDiscard()` 500 path. The trigger leaked into the next test processes
  via shared `db_test` state because the cleanup `defer` only ran on the
  happy-path exit. The fix wraps the trigger install in a savepoint with
  unconditional cleanup, so a normal audit INSERT always succeeds on the
  next connection acquired by the test runner.

**Priority:** MUST (ISS-0123 is a BLOCKER for `test-runner-step5c` regression).

**Test layer:** integration (real PostgreSQL via `BPM_TEST_DB_URL`).
The two test cases below are colocated in
`tests/integration/iss0123_regression_test.zig` and run against the existing
`helpers.TestHarness` (transaction rollback on deinit, no mocks, no stubs).

---

## Test Cases

### TC-ISS-0123-01 — production code no longer references the legacy `dead_letter_queue` table name (Cluster B source-assertion)

**Given:**
- The fix renames every `dead_letter_queue` literal in `src/` and
  `tests/integration/` to `dead_letter_items`.
- `src/design/dlq_rename_and_trigger_isolation.md` is the only place the
  legacy name should appear in source or test code.

**When:**
- The test walks `src/**/*.zig` and `tests/integration/**/*.zig` via
  `std.fs.cwd().walk`, reads each file as text, and counts occurrences of
  the literal `dead_letter_queue`.

**Then:**
- The count MUST be 0. Any non-zero count is reported as a list of
  `relative/path.zig:line` hits so the failing commit can be located
  immediately.
- The test fails with `error.TestUnexpectedResult` if the count is non-zero
  (no `error.SkipZigTest`).

**Layer:** integration (file-system inspection + `BPM_TEST_DB_URL` gate so
the test does not run if infrastructure is missing).

**Acceptance criterion mapped:** Cluster B — the source-assertion canary
that catches any re-introduction of the legacy table name. Equivalent in
intent to the new `tools/lint_sql_table_refs.py` linter (Cluster B
prevention), but is a runnable test that ties to the platform's test
suite so a regression is caught by the existing pipeline.

**Isolation:** No database writes; no state changes outside the test
process's own working directory. The walk is read-only.

---

### TC-ISS-0123-02 — `audit_entries` accepts a normal INSERT after the obs05 trigger savepoint cleanup (Cluster A audit-insert smoke)

**Given:**
- `helpers.TestHarness` (from `tests/integration/helpers.zig`) opens a
  fresh transaction against `BPM_TEST_DB_URL` and runs all pending
  migrations before the test body. The search_path is
  `tenant_default,public` so `audit_entries` resolves to the canonical
  tenant-schema table created by migration `020_obs03_audit_entries.sql`.
- The fix wraps `bpm_test_fail_audit_insert()` in a savepoint so the
  trigger cannot leak into the next pool connection.

**When:**
- The test allocates a per-test random UUID for `resource_id`, then
  issues:
  ```sql
  INSERT INTO audit_entries (actor_id, action, resource_type, resource_id)
  VALUES (NULL, 'regression.iss0123', 'dlq', $1::uuid);
  ```
  All other columns use their DEFAULT (`audit_id` from `gen_random_uuid()`,
  `timestamp` from `NOW()`, `before_state` / `after_state` from the column
  DEFAULT of `NULL`).

**Then:**
- The INSERT MUST succeed (no `P0001` from `bpm_test_fail_audit_insert()`,
  no `P0001` from `bpm_audit_immutable_guard()` — that guard fires only
  on UPDATE/DELETE).
- The test asserts success via `try h.conn.exec(...)` — any
  `error.ServerError` from the `pg.Conn` layer propagates as a test
  failure with the underlying PostgreSQL message.

**Layer:** integration. Real PostgreSQL, real `audit_entries` table, real
audit-chain triggers installed by migration `020_obs03_audit_entries.sql`.

**Acceptance criterion mapped:** Cluster A — proves the trigger
isolation is real, not just claimed. With the obs05 savepoint fix, a
fresh `TestHarness`-opened transaction has no `trg_bpm_test_fail_audit_insert`
on `audit_entries`, so a normal INSERT MUST succeed.

**Isolation:** Per-test random UUID (no shared state across test blocks).
Cleanup is automatic — `TestHarness.deinit()` rolls back the
transaction, so the inserted row never leaves the test session.

---

## Cleanup strategy

- **TC-01** is read-only: no DB or filesystem state to clean up.
- **TC-02** relies on the harness's transaction rollback (per
  `tests/integration/helpers.zig` §TestHarness.deinit). No explicit
  `DELETE FROM audit_entries` is needed; the rollback discards the
  inserted row.
- No `defer cleanup` is registered at the test level for either case
  because the harness owns the cleanup contract.

## Non-applicable rules

- **DIRECTIVE T-1 (no mocks/stubs):** the test connects to real
  PostgreSQL via `BPM_TEST_DB_URL`; no `error.SkipZigTest` is used.
- **Schema contract tests (§5 of `test_infrastructure_guide.md`):** this
  handoff is a regression suite, not a new-migration handoff. The
  schema is unchanged by the fix; no new `CHECK` constraints are
  introduced, so no `schema_contracts/` test is required.

## Wiring (not part of this handoff)

The new test file is created at
`tests/integration/iss0123_regression_test.zig`. It is **not** added
to `build.zig` (no `b.addTest` block) or `tests/integration/main_test.zig`
in this handoff because the task scope is restricted to the new test
+ spec files. BACKEND-DEV (or a follow-up TEST-DESIGNER step) is
responsible for:

1. Adding a `b.addTest` block in `build.zig` for
   `tests/integration/iss0123_regression_test.zig`, following the
   `iss0125_cascade_test.zig` pattern.
2. Adding the corresponding `test-integration-iss0123` step
   (parallel to `test-integration-iss0076`) and a barrier entry in
   `test_integration_others_step` (parallel to `run_iss0076_integration_tests.step`).
3. Optionally wiring the test into the `test-integration` umbrella
   step (parallel to `run_iss0076_integration_tests.step`).
4. Optionally appending a `const iss0123_regression_integration = ...`
   import to `tests/integration/main_test.zig` if the test is to be
   discovered via the umbrella entrypoint (not required for
   `test-integration-iss0123` to be runnable on its own).

These wiring steps are flagged as MAJOR-severity follow-up items in
the handoff `result.issues` so ORCH routes them to BACKEND-DEV or
TEST-DESIGNER as a follow-up workflow step.

## Requirement traceability

| Test | Cluster | Acceptance criterion |
|---|---|---|
| TC-ISS-0123-01 | B | No `dead_letter_queue` literal in `src/**/*.zig` or `tests/integration/**/*.zig` |
| TC-ISS-0123-02 | A | Normal `INSERT INTO audit_entries` succeeds on a fresh harness connection |

Both test cases are MUST. There is no DEFERRED work, no "future phase"
note, and no partial coverage.
