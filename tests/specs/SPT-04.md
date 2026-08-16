# Test Spec: SPT-04 — Test suite update and ADP-12 regression

**Requirement:** SPT-04 — The integration test suite MUST be updated to reflect schema-per-tenant isolation: all tests that previously inserted rows with an explicit `tenant_id` value MUST be updated to use per-test provisioned schemas via `provisionTenantSchema()` (or the test helper wrapper), and the `tenant_id` column references MUST be removed from all test fixtures and assertions. After the suite update, the full ADP-12 regression suite MUST pass against the `tenant_default` schema.
**Priority:** MUST
**Test layer:** integration (real PostgreSQL via `BPM_TEST_DB_URL`) + source-assertion
**Implementation:** `tests/integration/spt02_03_04_schema_tenant_migration_test.zig`
**Design authority:** `src/design/spt-02-03-04-schema-per-tenant-migration.md` §9, §15 (SPT-04 trace)

> **AC1 scope note (authoritative — mirrors OQ-1 precedent):** the literal grep
> `grep -r "tenant_id" tests/integration/` is unsatisfiable as written: Class-G registry
> references (`tenant_schemas.tenant_id`, `tenant_hostnames.tenant_id`, `public.tenant` fixture
> rows) legitimately remain, and the legacy-model suites (adp02/adp03/etc.) are reworked in a
> follow-up batch per the SECURITY-REVIEWER's Step 2c notes. The scoped interpretation for THIS
> suite: the SPT-02/03/04 test files and `helpers.zig` introduce **no** new explicit `tenant_id`
> INSERT / `set_config('bpm.tenant_id'` fixture, and use per-test provisioned schemas via
> `provisionTestTenantSchema()`/`dropTestTenantSchema()`.

## Test Cases

| TC ID | Name | Acceptance Criterion |
|---|---|---|
| TC-SPT-04-01 | SPT suite fixtures use per-test provisioned schemas (no new explicit `tenant_id` fixtures) | SPT-04 AC1 (scoped) |
| TC-SPT-04-02 | `zig build test-integration` coverage — every SPT-02/03/04 AC has a runnable, non-skipped test | SPT-04 AC2 |
| TC-SPT-04-03 | ADP-12 regression passes against `tenant_default` with no BLOCKER/MAJOR | SPT-04 AC3 |
| TC-SPT-04-04 | Provisioned schema + `tenant_schemas` row cleaned up after the test (no leakage) | SPT-04 AC4 |
| TC-SPT-04-05 | `zig build test` (unit) stays green — helpers + suite compile clean | SPT-04 AC5 |

### TC-SPT-04-01: SPT suite fixtures use per-test provisioned schemas (no new explicit `tenant_id` fixtures)

**Given:** The SPT-02/03/04 test suite and `helpers.zig` after this handoff.
**When:** `tests/integration/helpers.zig` and `tests/integration/spt02_03_04_schema_tenant_migration_test.zig` are scanned for the new-fixture anti-patterns (`set_config('bpm.tenant_id'`, `INSERT INTO ... (tenant_id,` on Class-B tables), and for the helper symbols.
**Then:** `provisionTestTenantSchema` and `dropTestTenantSchema` exist in `helpers.zig`; the SPT test file registers `defer dropTestTenantSchema(...)` for every provisioned schema and contains no explicit `set_config('bpm.tenant_id'` fixture.
**Layer:** integration + source-assertion
**Acceptance criterion mapped:** SPT-04 AC1 (scoped) — fixtures use per-test provisioned schemas; no residual fixture `tenant_id` in the new suite.

### TC-SPT-04-02: `zig build test-integration` coverage — every SPT-02/03/04 AC has a runnable, non-skipped test

**Given:** This suite's 16 test blocks (TC-SPT-02-01..06, TC-SPT-03-01..05, TC-SPT-04-01..05).
**When:** The suite runs against a real PostgreSQL.
**Then:** All 16 tests execute (no `error.SkipZigTest` on any MUST-covering block); each asserts its mapped AC; the run is deterministic (per-test UUIDs, no shared fixture state).
**Layer:** integration
**Acceptance criterion mapped:** SPT-04 AC2 — integration tests pass without skips on MUST coverage.

### TC-SPT-04-03: ADP-12 regression passes against `tenant_default` with no BLOCKER/MAJOR

**Given:** The ADP-12 stage matrix (`tests/integration/support/regression_matrix.zig`) is schema-agnostic and the default tenant routes to `tenant_default`.
**When:** The ADP-12 regression run is executed via `orchestrator.runRegressionSuite(...)` under `TestHarness` (which routes to `tenant_default`).
**Then:** The report shows `zero_diff_pass == true` and `pre_case_count == post_case_count == pair_count == matrix.len` (no BLOCKER/MAJOR).
**Layer:** integration
**Acceptance criterion mapped:** SPT-04 AC3 — ADP-12 all scenarios PASS against `tenant_default`, no BLOCKER/MAJOR.

### TC-SPT-04-04: Provisioned schema + `tenant_schemas` row cleaned up after the test (no leakage)

**Given:** A test provisions a per-test tenant schema and inserts a registry row via `provisionTestTenantSchema()`.
**When:** The test completes (success or failure) and `dropTestTenantSchema()` runs.
**Then:** The schema is gone from `information_schema.schemata`, the `tenant_schemas` row is deleted, and `schema_migrations`/`tenant` rows for that fixture are removed — a later probe finds zero leakage.
**Layer:** integration
**Acceptance criterion mapped:** SPT-04 AC4 — provisioned schema and its `public.tenant_schemas` row are cleaned up after the test (no schema leakage).

### TC-SPT-04-05: `zig build test` (unit) stays green — helpers + suite compile clean

**Given:** The new helpers and the SPT suite files are present in `tests/integration/`.
**When:** The suite artifact compiles and runs (this test exercises the helper path end-to-end).
**Then:** No compile fallout from the helper additions or struct-field removals; the helpers are usable from a real integration test (compile-clean consequence of AC5, whose full unit run is TEST-RUNNER's `zig build test`).
**Layer:** integration
**Acceptance criterion mapped:** SPT-04 AC5 — `zig build test` exits 0 with no test failures.
