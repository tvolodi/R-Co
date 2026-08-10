# BPM Platform — Test Infrastructure Methodology

**Version:** 1.0 · 2026-08-01  
**Author:** ORCH (post-mortem analysis of ISS-0112–ISS-0120)  
**Audience:** All agents — every agent that writes, runs, validates, or accepts tests  
**Status:** AUTHORITATIVE — rules here supersede earlier sections of `test_developer_guide.md` where they conflict

---

## 1. Why This Document Exists

In July–August 2026, 9 issues (ISS-0112 through ISS-0120) surfaced a cluster of failures that had nothing to do with wrong application logic and everything to do with **broken test infrastructure**. The pipeline accepted RELEASE-VALIDATOR sign-offs on stages whose integration tests were running against a corrupt, partial, or contaminated database. The test results were meaningless. The requirements were not truly verified.

The root causes fall into four classes:

| Class | What failed | Example issues |
|---|---|---|
| **A — Database baseline drift** | The test database schema did not match the current migration ledger; migrations were never applied, partially applied, or applied from a stale ledger | ISS-0112, ISS-0114 |
| **B — Fixture contamination** | Tests shared deterministic/hardcoded IDs; constraint violations from prior test runs left orphan rows; cleanup was ordered after foreign-key references still held | ISS-0113, ISS-0115 |
| **C — Schema/code contract drift** | Application constants (status strings, enum values, SQL parameter types) diverged from DB CHECK constraints across migrations; neither the migration nor the test caught the divergence | ISS-0118, ISS-0119, ISS-0120 |
| **D — Coverage gap** | A feature was implemented and accepted by the pipeline without the test validating the critical code path (the validation function was never invoked on the path under test) | ISS-0117 |

The current pipeline lacked any gate that asked: **"Is the test infrastructure itself healthy enough that test results can be trusted?"** This document defines that gate and the rules it enforces.

---

## 2. Three Infrastructure Invariants

These are unconditional rules. A test run that violates any one of them produces unreliable results and MUST NOT be used as evidence for PASS in a RELEASE-VALIDATOR decision.

### INV-TI-1 — Deterministic Baseline

> Before any integration test binary executes, the test database schema MUST be byte-identical to what `zig build migrate` produces on a freshly created database.

Concretely:
- The `bpm_test` database migration ledger (`public.schema_migrations`) must match the set of migration files in `migrations/`.
- All tenant schemas provisioned by prior test runs must either be cleaned up or recreated from the current migration baseline.
- No migration may be "recorded as applied" without having actually run its DDL — this includes idempotency guards that silently no-op (see anti-pattern: guard reads wrong schema).

Verification command (TEST-RUNNER must run this before any test binary). The single
command surface's `./make.ps1 migrate` (GH-294 / ISS-0079 / PI-04) wraps `zig build
migrate` with `BPM_DB_URL` sourced from `.env` — but note §3 below requires the DB URL
to be `BPM_TEST_DB_URL`, not `.env`'s default `BPM_DB_URL`, so use `./make.ps1
test-live` (which targets the test database) or the raw override form when verifying
this invariant specifically:
```bash
zig build migrate 2>&1
# Must exit 0. Any output containing "already exists", "ERROR", or "FAILED" = baseline drift.
python3 tools/verify_schema_baseline.py  # (see §6 for required checks)
```

### INV-TI-2 — Strict Per-Test Isolation

> No integration test may read, modify, or depend on state created by any other test, test binary, or prior pipeline run.

Concretely:
- Every test block creates its own fixtures using per-test UUIDs (from `std.crypto.random` or the simulation UUID source — never hardcoded).
- Every test block registers `defer cleanup()` **before** any operation that creates database state, so cleanup runs even if the test panics or fails mid-way.
- Cleanup deletes in foreign-key dependency order: children before parents.
- If a test block needs a tenant, it creates and owns that tenant. It does not use the `default` tenant created by the harness seed unless that seed is explicitly reset as part of setup.
- `lint_test_isolation.py` must exit with no BLOCKER findings before TEST-RUNNER starts.

### INV-TI-3 — Schema/Code Contract Parity

> Every value that both application code and a DB constraint care about must be defined in exactly one place and derived everywhere else.

Concretely:
- Application status strings, enum values, and column names used in `INSERT`/`UPDATE`/`WHERE` clauses must match the live `CHECK` constraint exactly.
- When a migration adds or modifies a `CHECK` constraint, the application constants that feed those values MUST be updated in the same PR — not later.
- A schema contract test (see §5) must assert that the DB constraint accepts all application-side values and rejects known-invalid ones.
- SQL placeholders (`$1`, `$2`, …) that are used in contexts where PostgreSQL cannot infer the type must carry an explicit `::type_name` cast. This is enforced by running the statement against a real PostgreSQL instance during BACKEND-DEV validation — not by review alone.

---

## 3. Infrastructure Health Checklist

This checklist is the definition of "healthy test infrastructure". TEST-RUNNER executes it before dispatching any test binary. Each item is a hard gate: failure → STOP, return FAIL with severity BLOCKER, reason = "Test infrastructure unhealthy".

**Every item below is about one database: the one `BPM_TEST_DB_URL` names.** That
is the database the integration tests open, so it is the only one whose health
this checklist asserts. An item that verifies a *different* database — however
green it looks — tells you nothing (see ISS-0180 / GH #511, where `zig build
migrate` was migrating `BPM_DB_URL`'s development database while the baseline
check inspected `BPM_TEST_DB_URL`'s test database, and reported PASS and FAIL in
the same run).

```
[ ] BPM_TEST_DB_URL is set, and BPM_DB_URL does not resolve to the same
       host:port/database (dev and test must be distinct databases)
[ ] docker-compose ps shows db_test as "healthy", AND that container publishes
       the port in BPM_TEST_DB_URL (a container merely named db_test may belong
       to a different workspace on the same host)
[ ] zig build migrate exits 0 with no error output, run against BPM_TEST_DB_URL
[ ] public.schema_migrations row count for schema_name='public' in the TEST
       database == count of files in migrations/
[ ] All tenant schemas expected by the integration test suite exist
       (verified by: python3 tools/verify_schema_baseline.py --check-tenants)
[ ] zig build exits 0 (no compile errors)
[ ] python3 tools/lint_test_isolation.py tests/integration exits 0, no BLOCKER
[ ] No stale lock rows in pg_locks for the test database from prior sessions
       (verified by: psql $BPM_TEST_DB_URL -c "SELECT count(*) FROM pg_locks WHERE NOT granted" -> must be 0)
[ ] Every running compose service's container config-hash label matches the
       CURRENT docker-compose.yml (GH-542 / ISS-0607 / ISS-0608). Some
       settings (e.g. POSTGRES_HOST_AUTH_METHOD) are applied only at
       container-creation time — a container left running since before a
       docker-compose.yml change never picks up the new value on a plain
       restart or `docker-compose up` (which reuses an existing container),
       and every other check above can still pass while this one silently
       drifts. Verified via Docker Compose's own
       `com.docker.compose.config-hash` label, which it already stamps on
       every container it creates — this catches drift in ANY setting for
       ANY service, not just one hand-picked variable.
```

Do not run these by hand and judge them by eye. `zig build test-env-verify`
executes all of them as checks C0–C7 and reports a single exit code (0 =
healthy), and it prints the resolved database URLs so the subject of each check
is visible rather than assumed. Judge it by the exit code only.

Note that `src/tools/migrate.zig` reads `BPM_DB_URL` by contract — that is also
the production bootstrap path and is deliberately unchanged. `verify_test_env.py`
therefore overrides `BPM_DB_URL` in the migrate child process only, pointing it
at `BPM_TEST_DB_URL`. If you invoke `zig build migrate` manually to prepare the
test database, you must do the same:

```bash
BPM_DB_URL="$BPM_TEST_DB_URL" zig build migrate
```

`./make.ps1 test-live` (single command surface, GH-294 / ISS-0079 / PI-04) waits for
Postgres + Keycloak and then runs `zig build test-integration` against
`BPM_TEST_DB_URL` sourced from `.env` — it does not itself run `migrate` against the
test database (that is `zig build test-integration`'s own responsibility per the
existing contract above), so this manual override remains the correct form when
preparing the test database's schema ahead of time by hand.

If any item fails, TEST-RUNNER reports FAIL and instructs ORCH to create an ADHOC BACKEND-DEV handoff before retrying.

---

## 4. Green-Main Gate (Pre-Cycle Regression Check)

**Rule:** ORCH MUST NOT start a WF-02 implementation pipeline for new requirements if any integration test is currently failing on `main`.

This is enforced as **Step 00a** in WF-02 (see §7).

The rationale: implementing new features on top of a broken test suite produces false confidence. A test that was already red before the feature was added and turns green after is not evidence the feature works — it is coincidence. A test that was green and turns red after is masked by the pre-existing failures.

Step 00a procedure (steps 3–4 are `./make.ps1 test` and `./make.ps1 test-live` on the
single command surface — GH-294 / ISS-0079 / PI-04 — which sources env vars from
`.env` and, for step 4, blocks on real service readiness before invoking
`test-integration`):
1. Pull the current `main` branch.
2. Run the Infrastructure Health Checklist (§3).
3. Run `zig build test` (unit tests) → must exit 0.                    [`./make.ps1 test`]
4. Run `zig build test-integration` → must exit 0.                     [`./make.ps1 test-live`]
5. If any step fails: classify failures into ISS entries (each with its mandatory GitHub issue), forward each cluster to the global queue via `python3 tools/queue_add.py`, and hold WF-02 until those issues have been fixed by their own WF-03 runs and `main` is green again. Each cluster is its own run with its own branch and PR — see `docs/agents/protocols/ISSUE_QUEUE.md` and `docs/agents/protocols/LOOP_PROTOCOL.md`.
6. Only after a clean run of steps 2–4 may ORCH stamp Step 00a PASS and proceed to Step 00 (git-setup).

---

## 5. Schema Contract Tests

**Rule:** Every migration that creates or modifies a `CHECK` constraint, `ENUM`, `FOREIGN KEY` domain, or column used in application status logic MUST be accompanied by a schema contract test in the same PR.

A schema contract test is a Zig integration test in `tests/integration/schema_contracts/` that:
1. Verifies the constraint exists and has the expected form (via `information_schema.check_constraints` or `pg_catalog.pg_constraint`).
2. Verifies every application-side value INSERT succeeds.
3. Verifies a known-invalid value INSERT fails with `23514` (check_violation).

Template:
```zig
// tests/integration/schema_contracts/webhook_delivery_status_test.zig
test "SC-webhook_deliveries_status_check: application values accepted, invalid rejected" {
    var h = try TestHarness.init();
    defer h.deinit();

    // Every value the application can write — all must succeed
    const valid = [_][]const u8{ "pending", "delivered", "failed", "retrying", "dead" };
    for (valid) |status| {
        try h.conn.exec(
            "INSERT INTO webhook_deliveries (id, subscription_id, status) VALUES ($1, $2, $3)",
            .{ testUuid(), testUuid(), status },
        );
    }

    // A value the application must never write — must fail with 23514
    try testing.expectError(
        error.CheckViolation,
        h.conn.exec(
            "INSERT INTO webhook_deliveries (id, subscription_id, status) VALUES ($1, $2, $3)",
            .{ testUuid(), testUuid(), "BOGUS" },
        ),
    );
}
```

TEST-DESIGNER is responsible for writing these tests whenever BACKEND-DEV's migration adds a constraint. TEST-DESIGN-VALIDATOR must verify they exist before passing the handoff.

---

## 6. Database Baseline Verification Tool

`tools/verify_schema_baseline.py` is the authoritative baseline checker. It must:

1. Connect to `$BPM_TEST_DB_URL`.
2. Count rows in `public.schema_migrations` and compare to `len(glob("migrations/*.sql"))`. Mismatch → FAIL.
3. For each migration file, verify the corresponding row exists in `public.schema_migrations`. Gap → FAIL with the missing file name.
4. For each tenant in `public.tenants`, verify `tenant_schema_name` exists as a PostgreSQL schema. Missing schema → FAIL.
5. For each migration file whose name starts with `GBL-`, verify the DDL's key object exists in `public` schema (spot-check by parsing the first `CREATE TABLE`/`CREATE INDEX`/`ALTER TABLE` statement).
6. Run the Infrastructure Health Checklist items that are checkable via SQL.

Until this tool is implemented, TEST-RUNNER approximates it with the following manual checks:
```bash
psql $BPM_TEST_DB_URL -c "SELECT count(*) FROM public.schema_migrations"
# compare to: (Get-ChildItem migrations/*.sql | Measure-Object).Count
psql $BPM_TEST_DB_URL -c "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'tenant_%'"
# must match tenants registered in public.tenants
```

---

## 7. Workflow Integration — Where Infrastructure Gates Live

### WF-02: Requirement Implementation

```
Step 00a  TEST-RUNNER         Green-Main Gate (§4)  ← NEW HARD GATE
Step 00   BACKEND-DEV         fn:git-setup
Step 1    CODE-DESIGNER
Step 1b   CODE-DESIGN-VALIDATOR   Hard gate
Step 2a   BACKEND-DEV         fn:implement
Step 2b   FRONTEND-DEV        fn:implement
Step 3    TEST-DESIGNER       (includes schema contract tests for any new migrations)
Step 3b   TEST-DESIGN-VALIDATOR   Hard gate
          └── verifies schema contract tests exist per §5
Step 4    TEST-RUNNER         Infrastructure Health Checklist (§3) THEN run tests
Step 5    RELEASE-VALIDATOR
Step 6    DOC-UPDATER
Final     BACKEND-DEV         fn:git-merge
```

**Step 00a is a hard gate.** ORCH MUST NOT dispatch Step 00 until Step 00a returns PASS.

If Step 00a returns FAIL, ORCH files each failure cluster and forwards it to the global queue (using the same issue classification as any other regression). Each becomes its own WF-03 run. ORCH redispatches Step 00a once those runs have merged — WF-02 does not proceed on a red `main`, and it does not absorb the fixes into its own branch.

### WF-03: Issue Resolving

Same Step 00a applies. A fix applied to a broken codebase cannot be validated reliably. Step 00a must pass before BACKEND-DEV's fix goes in.

### WF-04: Full Test Run

Step 00a is the natural entry point — the entire purpose of WF-04 is to run a clean suite. The Infrastructure Health Checklist (§3) is the first action.

---

## 8. Agent Responsibilities Summary

| Agent | New Responsibility |
|---|---|
| **ORCH** | Enforce Step 00a as a hard gate in WF-02 and WF-03. Route Step 00a failures to WF-03 immediately. |
| **BACKEND-DEV** | When writing a migration that adds/modifies a CHECK constraint or column, update the corresponding application constants in the same commit. Run `python3 tools/verify_schema_baseline.py` after `zig build migrate` as part of self-review. |
| **TEST-DESIGNER** | Add a schema contract test (§5) for every migration that creates/modifies a constraint or enum. Per-test UUIDs are non-negotiable — no hardcoded IDs, ever. |
| **TEST-DESIGN-VALIDATOR** | Verify schema contract tests exist for each new migration's constraints. Fail the handoff if they are absent. Run `lint_test_isolation.py` — BLOCKER findings block PASS. |
| **TEST-RUNNER** | Run the Infrastructure Health Checklist (§3) before any test binary. Return FAIL with BLOCKER severity if any checklist item fails. After all tests pass, run the checklist again to confirm no test left the infrastructure in a degraded state. |
| **RELEASE-VALIDATOR** | Confirm that TEST-RUNNER's run report explicitly states the Infrastructure Health Checklist passed. A report that skips this section is not a valid test report. |

---

## 9. Isolation Pattern Reference

### Correct pattern: per-test UUIDs with unconditional defer cleanup

```zig
test "TC-EXT-02-01: webhook delivery is persisted" {
    var h = try TestHarness.init();
    defer h.deinit();                        // rolls back tx unconditionally

    const sub_id = try h.newUuid();          // per-test unique ID from TestHarness
    const delivery_id = try h.newUuid();

    // TestHarness.deinit() rolls back the transaction — no explicit cleanup needed
    // for rows created within the transaction.
}
```

### Correct pattern: cleanup registered before state creation

```zig
test "TC-TM-04-01: deactivated tenant cannot be used" {
    var h = try TestHarness.init();
    defer h.deinit();

    const tenant_id = try createTestTenant(h.conn, "slug-" ++ testSuffix());
    defer deleteTestTenant(h.conn, tenant_id) catch {};  // registered BEFORE any dependent inserts

    try createInstanceForTenant(h.conn, tenant_id);
    // ... rest of test
}
```

### Forbidden patterns

```zig
// FORBIDDEN: hardcoded ID that collides across test runs
const SUB_ID = "00000000-0000-0000-0000-000000000042";

// FORBIDDEN: no cleanup for state that survives the transaction (e.g. advisory locks)
test "..." {
    pg_advisory_lock(42);
    // ... forgot defer pg_advisory_unlock(42)
}

// FORBIDDEN: one test reading state another test created
test "TC-X-02: verify TC-X-01's result" {
    // reads rows left by TC-X-01 — order dependency
}
```

---

## 10. Quick Reference: Anti-Patterns from ISS-0112–ISS-0120

| Pattern | Issue | Rule violated |
|---|---|---|
| Running integration tests against a long-lived, never-reset test DB | ISS-0112, ISS-0114 | INV-TI-1 |
| Hardcoded idempotency keys shared across test binaries | ISS-0113 | INV-TI-2 |
| App status constant (`"pending"`) not matched against live DB CHECK constraint | ISS-0118 | INV-TI-3 |
| SQL `$2` placeholder used without explicit cast in ambiguous context | ISS-0120 | INV-TI-3 |
| Timer state machine tested without verifying DB transaction boundary | ISS-0119 | INV-TI-1 |
| EXP-401 validation path never invoked on the test graph | ISS-0117 | §5 coverage gap |
| DLQ schema state not verified before persistence tests | ISS-0116 | INV-TI-1 |
| Task claim concurrency tested in shared-state DB with no isolation | ISS-0115 | INV-TI-2 |
| Tenant schema absent at test time, not detected before test run | ISS-0114 | §3 Health Checklist |
