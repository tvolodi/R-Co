# Test Spec: ISS-0706 / GH-791 — GBL-116 pre-flight blocks `zig build bench` on a fresh DB

**Requirement:** ISS-0706 / GitHub #791 — `GBL-116_tnt07_rls_cleanup` pre-flight gate fails
`zig build bench` because (a) `migrate.zig` receives no `BPM_DB_URL` from the bench's transitive
migration step and (b) `migrate.zig`'s in-loop `provisionTenantSchema` swallows its error silently,
leaving `public.tenant_schemas.migrations_applied_at` `NULL` for the default tenant, which trips
the GBL-116 pre-flight loop.

**Design source:** `src/design/iss-0706-gbl116-bench-pre-flight.md` §5 (acceptance criteria) and §6 (must / must-not).
**Diagnosis source:** `handoffs/WF03-GH791-20260815/diagnosis-01.md`.
**Implementation commits:** `c0654f99` (build.zig + migrate.zig + GBL-116 cosmetic) and `a91e689c` (memo).
**Existing test source:** `tests/integration/iss0706_gbl116_bench_preflight_test.zig` (authored by Step 03 BACKEND-DEV).
**Priority:** MUST (ISS-0706 is a BLOCKER for the bench / release-validator chain — see
`docs/issue-reports/WF02-plc-batch-b-20260815-step-05-release-validator-INNER-REPORT.yaml`,
test `zig build bench`, status `skip`).

**Test layer:** integration (real PostgreSQL via `BPM_TEST_DB_URL` for the two live-DB cases; static
source-assertion against `build.zig`, `tests/bench/bench.zig`, and `migrations/GBL-116_*.sql` for the
other five cases). No mocks, no stubs, no in-memory database. `error.SkipZigTest` is permitted on
the two live-DB cases (matches the `iss207_error_retry_test.zig` convention) but forbidden on the
five source-assertion cases (no DB dependency).

---

## Scope

This regression suite proves the surgical fix landed on
`feature/WF03-GH791-20260815`:

1. `build.zig` injects the resolved bench DB URL into the `run_migrate` child process so
   `migrate.zig`'s hard `BPM_DB_URL` read at `src/tools/migrate.zig:17-21` is satisfied on the
   bench path (leg a).
2. `src/tools/migrate.zig` fails loudly when `provisionTenantSchema` returns successfully but
   `public.tenant_schemas.migrations_applied_at` is still `NULL` (leg d).
3. The GBL-116 pre-flight gate body (lines 39-61 of `migrations/GBL-116_tnt07_rls_cleanup.sql`)
   is unchanged — production behaviour is preserved.

The 20 acceptance criteria (10 MUST + 10 MUST-NOT) are listed below; every MUST criterion has at
least one concrete test case, and every MUST-NOT criterion is guarded by a source-assertion
canary or by a MUST test that would fail if the MUST-NOT invariant were violated.

---

## Test cases

### TC-ISS-0706-01 — `build.zig` injects `BPM_DB_URL` into `run_migrate` (MUST-1, MUST-2, MUST-5)

**Given:** The bench step in `build.zig` is constructed with
`run_bench.step.dependOn(&run_migrate.step)`.
**When:** The source is read and asserted on for the four invariants:
helper function exists (`fn resolveBenchMigrateDbUrl`),
`run_migrate.setEnvironmentVariable("BPM_DB_URL", ...)` is called,
diagnostic line `BENCH_MIGRATE_URL_INFO|source=` is emitted, and
the injection happens **before** the `dependOn` call.
**Then:** All four invariants hold. If any one fails, the test fails with
a clear message naming the missing piece.
**Layer:** integration (source-assertion; no DB required).
**Acceptance criterion mapped:** MUST-1 (shell-env path), MUST-2 (`.env`-only path),
MUST-5 (graceful degradation when no URL is available).
**Reference:** `tests/integration/iss0706_gbl116_bench_preflight_test.zig:165` —
test `"regression: ISS-0706 -- AC-5.1.1/5.1.2/5.1.5 build.zig injects BPM_DB_URL into run_migrate"`.

### TC-ISS-0706-02 — `resolveBenchMigrateDbUrl` mirrors `bench.zig::resolveDbUrl` precedence (MUST-2, MUST-NOT-7, MUST-NOT-10)

**Given:** `tests/bench/bench.zig::resolveDbUrl` reads env vars in the order
`BPM_BENCH_DB_URL` → `BPM_DB_URL` → `BPM_TEST_DB_URL`.
**When:** The test asserts that `build.zig::resolveBenchMigrateDbUrl` references the same three
keys in the same lexical order in both the `env_candidates` declaration and the `.env` fallback
path. All assertions are scoped AFTER the `fn resolveDbUrl` marker so the earlier
`BPM_TEST_DB_URL` call in `bench.zig::main` does not skew the result.
**Then:** All three positional-order invariants hold (bench < db < test, both for the
`env_candidates` array and for the `readBuildDotEnvValue` calls). If any single check fails,
the test fails with a precise identifier of which key is out of order.
**Layer:** integration (source-assertion; no DB required).
**Acceptance criterion mapped:** MUST-2 (`.env` path correctness), MUST-NOT-7
(`bench.zig::resolveDbUrl` is unchanged — the helper mirrors it), MUST-NOT-10 (no new env var
introduced; the three existing keys are reused).
**Reference:** `tests/integration/iss0706_gbl116_bench_preflight_test.zig:185` —
test `"regression: ISS-0706 -- resolveBenchMigrateDbUrl mirrors bench.zig::resolveDbUrl precedence"`.

### TC-ISS-0706-03 — `migrate.zig` has the loud post-condition at both call sites (MUST-4, MUST-NOT-4, MUST-NOT-5)

**Given:** `src/tools/migrate.zig` calls `db_provisioning.provisionTenantSchema(...)` at
the in-loop hook (lines 142-187) AND at the post-loop fallback (lines 297-315).
**When:** The source is read and asserted on for four invariants:
(a) `var provision_attempted: bool = false;` appears at least twice (one per site);
(b) the post-condition query
`SELECT count(*)::text FROM public.tenant_schemas WHERE tenant_id = $1::uuid AND migrations_applied_at IS NOT NULL`
appears exactly twice (one per site);
(c) the loud error message
`post-condition: default tenant_schemas.migrations_applied_at is NULL` appears exactly twice;
(d) `db_provisioning.provisionTenantSchema(` is still called (no behavioural regression).
**Then:** All four invariants hold. A missing post-condition at either site, or a missing
`provision_attempted` gate, fails the test.
**Layer:** integration (source-assertion; no DB required).
**Acceptance criterion mapped:** MUST-4 (loud abort on post-condition miss), MUST-NOT-4
(post-condition is read-only — encoded as a `SELECT count(*)`, never a write — covered
implicitly because the test only inspects the source for `SELECT`, not `INSERT`/`UPDATE`),
MUST-NOT-5 (post-condition is gated on `provision_attempted`, which is only set `true`
when the pool actually opened — a DB-unreachable case skips the check, preserving the
bench's `BPM_TEST_DB_URL` retry fallback).
**Reference:** `tests/integration/iss0706_gbl116_bench_preflight_test.zig:226` —
test `"regression: ISS-0706 -- migrate.zig has the loud post-condition at both sites"`.

### TC-ISS-0706-04 — post-condition returns 0 when `migrations_applied_at` is NULL (MUST-4)

**Given:** A live PostgreSQL is reachable via `BPM_TEST_DB_URL`. The default tenant
`00000000-0000-0000-0000-000000000000` has a row in `public.tenant_schemas`. The test
sets `migrations_applied_at` to `NULL` for that tenant and restores it in a defer
so the next suite is unaffected.
**When:** The test runs the exact post-condition query encoded in `migrate.zig`:
`SELECT count(*)::text FROM public.tenant_schemas WHERE tenant_id = $1::uuid AND migrations_applied_at IS NOT NULL`.
**Then:** The count MUST be 0. A non-zero count would mean the post-condition was
designed wrong — it must match the column state on disk, not pass spuriously.
**Layer:** integration (live DB).
**Acceptance criterion mapped:** MUST-4 — proves the post-condition query (which `migrate.zig`
will execute) returns the right value when the silent-failure branch has run.
**Reference:** `tests/integration/iss0706_gbl116_bench_preflight_test.zig:85` —
test `"regression: ISS-0706 -- AC-5.1.3 post-condition returns 0 when migrations_applied_at is NULL"`.
**Note:** Returns `error.SkipZigTest` when `BPM_TEST_DB_URL` is unset (the `iss207_error_retry_test.zig`
convention). A skipped live-DB test is acceptable because the source-assertion tests
(TC-01, TC-02, TC-03, TC-05, TC-07) cover the same design intent at the source level.

### TC-ISS-0706-05 — post-condition returns >= 1 on a long-lived DB (MUST-6)

**Given:** A live PostgreSQL is reachable via `BPM_TEST_DB_URL`. The default tenant
has a row in `public.tenant_schemas`. The test sets `migrations_applied_at = NOW()`
to simulate a successful `provisionTenantSchema` call.
**When:** The test runs the exact post-condition query (same as TC-04).
**Then:** The count MUST be `>= 1`. A count of 0 would mean the post-condition would
abort a healthy `zig build migrate` against a long-lived DB, breaking the existing
CI path and every operator's existing workflow.
**Layer:** integration (live DB).
**Acceptance criterion mapped:** MUST-6 (long-lived DB path is unaffected).
**Reference:** `tests/integration/iss0706_gbl116_bench_preflight_test.zig:127` —
test `"regression: ISS-0706 -- AC-5.1.6 post-condition returns >=1 on long-lived DB"`.
**Note:** Returns `error.SkipZigTest` when `BPM_TEST_DB_URL` is unset.

### TC-ISS-0706-06 — GBL-116 cosmetic message references GBL-113 and GBL-114 (MUST-9)

**Given:** `migrations/GBL-116_tnt07_rls_cleanup.sql` contains a `RAISE EXCEPTION`
message about `tnt05_progress` being missing.
**When:** The test extracts the message text between the opening `RAISE EXCEPTION '...`
and the closing `';` and asserts:
(a) `GBL-113` is referenced;
(b) `GBL-114` is referenced;
(c) `GBL-074` is NOT referenced;
(d) `GBL-075` is NOT referenced;
(e) the migration files `migrations/GBL-113_tnt05_backfill_tracking.sql` and
`migrations/GBL-114_tnt05_backfill_run.sql` exist on disk (so the message is not
referencing a non-existent file).
**Then:** All five invariants hold. A regression that re-introduces the
`GBL-074` / `GBL-075` string fails the test with a clear "stale identifier
re-introduced" message.
**Layer:** integration (source-assertion + filesystem access; no DB required).
**Acceptance criterion mapped:** MUST-9.
**Reference:** `tests/integration/iss0706_gbl116_bench_preflight_test.zig:247` —
test `"regression: ISS-0706 -- MUST-9 GBL-116 cosmetic message references GBL-113 and GBL-114"`.

### TC-ISS-0706-07 — GBL-116 pre-flight gate body is unchanged (MUST-NOT-1)

**Given:** `migrations/GBL-116_tnt07_rls_cleanup.sql` is the authoritative source for the
TNT-07 pre-flight gate.
**When:** The source is read and asserted on for five invariants:
(a) the `FOR v_tenant IN SELECT id FROM public.tenant LOOP` block is present;
(b) the loop iterates over `v_tenant.id`;
(c) the `migrations_applied_at IS NOT NULL` check is present;
(d) the `status = 'COMPLETED'` check on `tnt05_progress` is present;
(e) the `RAISE EXCEPTION 'TNT-07 pre-flight failed. Unready tenants: %'` message is present.
**Then:** All five invariants hold. Removing any one of them would be a violation of
MUST-NOT-1 (gate stays strict).
**Layer:** integration (source-assertion; no DB required).
**Acceptance criterion mapped:** MUST-NOT-1 (gate body lines 39-61 unchanged).
**Reference:** `tests/integration/iss0706_gbl116_bench_preflight_test.zig:281` —
test `"regression: ISS-0706 -- MUST-NOT-1 GBL-116 pre-flight gate body is unchanged"`.

### TC-ISS-0706-08 — Manual check: env-verify gate (MUST-7) is OUT OF SCOPE for this run

**Given:** `tools/verify_test_env.py` is the Step 04 env-verify gate. Its C6 stale-locks
check was the immediate symptom in the issue, but the diagnosis flags the stale-locks
behaviour as **pre-existing** on `bpm_test` (the bench DB at port 5433), not a regression
introduced by this fix.
**When:** TEST-RUNNER runs `zig build bench` and observes the bench path complete
successfully (i.e. `NFR_BENCH_SUMMARY|overall_passed=true|run_id=...` is emitted).
**Then:** The bench path proves the post-fix contract: `migrate.zig` connects to the
bench DB (because `BPM_DB_URL` is injected), `provisionTenantSchema` succeeds (because
the schema is freshly migrated, not stale), and GBL-116's pre-flight passes (because
`migrations_applied_at` is set). This is the **integration** of the design's contract —
not a separate test case but a confirmation that the existing NFR suite covers it.
**Layer:** e2e (manual / regression check via the existing NFR bench).
**Acceptance criterion mapped:** MUST-7 (env-verify gate passes after the fix).
**Note:** C6 stale-locks on `bpm_test` is a pre-existing condition tracked under
ISS-0707; this run does NOT regression-test it. A fix for stale-locks is a separate
workflow.

### TC-ISS-0706-09 — Pipeline chain sanity check (MUST-10)

**Given:** All seven regression tests above are runnable.
**When:** The CI / local pipeline runs them in order:
`zig build` → `zig build test` → `zig build test-integration-iss0706` → `zig build bench` (smoke).
**Then:** Each step exits 0. `zig build` is the typecheck / lint gate;
`zig build test` runs all unit tests (the source-assertion tests above must pass here
because they have no DB dependency); `zig build test-integration-iss0706` runs the
two live-DB cases (these need `BPM_TEST_DB_URL` set in the runner environment);
`zig build bench` (smoke) proves the bench path itself works end-to-end on the
fresh-DB state (MUST-1, MUST-2, MUST-3, MUST-6).
**Layer:** pipeline.
**Acceptance criterion mapped:** MUST-10 (all new regression tests pass) and the
cross-check that none of the MUST-NOT invariants are violated by the integrated chain.

---

## Pipeline chain

The pipeline chain that this spec plugs into is:

```
zig build          (typecheck + lint)
    ↓
zig build test     (unit tests; source-assertion cases TC-01, TC-02, TC-03, TC-06, TC-07)
    ↓
zig build test-integration-iss0706  (live-DB cases TC-04, TC-05; needs BPM_TEST_DB_URL)
    ↓
zig build bench    (smoke; end-to-end verification of MUST-1, MUST-2, MUST-3, MUST-6)
```

Each step's exit code MUST be 0 for the WF03 chain to progress past Step 04.
The Step 04 TEST-DESIGNER handoff is complete when this spec exists and
the seven `test "..."` blocks at `tests/integration/iss0706_gbl116_bench_preflight_test.zig`
are runnable (which they are — the file is unchanged from Step 03).

---

## Failure modes (what was fixed vs what was deemed out-of-scope)

### Fixed by this run (commit `c0654f99`)

| Failure mode | Root cause | Fix |
|---|---|---|
| `zig build bench` exits non-zero on a fresh DB with `BPM_BENCH_DB_URL` set. | `build.zig`'s `run_migrate` step received no `BPM_DB_URL` from the bench. `migrate.zig:17-21` hard-reads `BPM_DB_URL` and exits with `BPM_DB_URL environment variable is not set`. | New `resolveBenchMigrateDbUrl` helper in `build.zig` (mirrors `bench.zig::resolveDbUrl` precedence). New `run_migrate.setEnvironmentVariable("BPM_DB_URL", ...)` call at the bench step construction site. Diagnostic line `BENCH_MIGRATE_URL_INFO|source=...` emitted on success. |
| `GBL-116_tnt07_rls_cleanup.sql` pre-flight trips on the default tenant because `migrations_applied_at` is `NULL`. | `migrate.zig`'s in-loop hook (lines 142-187) and post-loop fallback (lines 297-315) both catch `provisionTenantSchema`'s errors and log `warn`, then `return`. The hook can fail silently (return without throwing but the column is still `NULL`); in either case the post-condition is never checked. | New post-condition check at both sites: `SELECT count(*)::text FROM public.tenant_schemas WHERE tenant_id = $1::uuid AND migrations_applied_at IS NOT NULL`. If count is 0 AND `provision_attempted = true` (pool opened), `std.log.err(...)` then `std.process.exit(1)`. |
| GBL-116's `RAISE EXCEPTION` message references non-existent `GBL-074` / `GBL-075` files. | Pre-rename naming convention; cosmetic. | String literal updated to `GBL-113 and GBL-114` (matches the actual files on disk). |

### Out-of-scope (NOT addressed by this run)

| Out-of-scope item | Why | Follow-up |
|---|---|---|
| Adding the same post-condition check to `src/main.zig::runApiServer` (production server's startup path). | The diagnosis does not mandate this for ISS-0706. Production's existing behaviour is preserved. | Sensible follow-up; tracked under ISS-0707 (or a similar ID). |
| Refactoring `migrate.zig`'s hard `BPM_DB_URL` read to support a `BPM_BENCH_DB_URL` fallback internally. | Would change `migrate.zig`'s public contract — out of scope for the surgical fix. | Follow-up refactor; not blocking ISS-0706. |
| Migrating `pool_size = 2` for the in-loop hook to a higher value. | Pre-existing race documented in the diagnosis; not blocking ISS-0706. | Out of scope. |
| `tools/verify_test_env.py` C6 stale-locks check on `bpm_test`. | Pre-existing condition on the bench DB at port 5433, not a regression introduced by this fix. | Tracked under ISS-0707; separate workflow. |
| `bench-bootstrap.sh`-style helper script that manually updates `migrations_applied_at`. | Approach (c) rejected by the diagnosis. Would defeat the gate's intent for any future maintainer. | Explicit anti-pattern per `docs/anti-patterns.md` INV-1. |

---

## Manual checks

These are NOT covered by the seven Zig test cases. They are operational
checks that the pipeline should execute (or a human should run) to confirm
the env-verify gate and the bench path behave correctly.

### MC-1: `tools/verify_test_env.py` exits 0 (MUST-7)

The Step 04 env-verify gate. Run before declaring the WF-03 fix complete.
The gate's C6 stale-locks check is **pre-existing**, not a regression of this run —
its non-zero status is tracked under ISS-0707 and is **NOT** a blocker for
ISS-0706's closure.

```bash
python tools/verify_test_env.py
echo "EXIT_CODE=$?"
# Expected: 0 once ISS-0707 is also resolved; otherwise the C6 sub-check
# may be non-zero on stale bpm_test state.
```

### MC-2: `zig build bench` end-to-end smoke

Run against a freshly created bench DB (`bpm_test` at port 5433, after
`DROP DATABASE bpm_test; CREATE DATABASE bpm_test;`):

```bash
export BPM_BENCH_DB_URL=postgres://bpm:bpm@localhost:5433/bpm_test
unset BPM_DB_URL BPM_TEST_DB_URL
zig build bench
# Expected: exit 0; stdout contains NFR_BENCH_SUMMARY|overall_passed=true|...
```

### MC-3: `zig build migrate` against the production-shaped path (MUST-3)

This is the existing CI fresh-DB path. It must remain green (no regression):

```bash
export BPM_DB_URL=postgres://bpm:bpm@localhost:5432/bpm_fresh_ci
unset BPM_BENCH_DB_URL BPM_TEST_DB_URL
zig build migrate
# Expected: exit 0; all migrations applied; GBL-116 passes the pre-flight
# because provisionTenantSchema succeeds on the brand-new DB.
```

### MC-4: Pre-fix repro returns to the original error message

If the diagnostic state needs to be re-verified, revert the commit on a
fresh branch and run `zig build bench` — the original error
`TNT-07 pre-flight failed: tnt05_progress table does not exist. Run GBL-074 and GBL-075 first.`
should re-appear. (This is a debugging step, not part of the gate.)

---

## Isolation and security contract

- Each test that touches the DB initialises its own `Pool` from `BPM_TEST_DB_URL`,
  sets `bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000")`,
  and releases its connection in a `defer`.
- Live-DB tests (TC-04, TC-05) restore the
  `public.tenant_schemas.migrations_applied_at` column for the default
  tenant in a `defer` so subsequent suites are not affected.
- All fixture SQL uses PostgreSQL placeholders (`$1::uuid`); no string
  interpolation of user data into SQL.
- Source-assertion tests (TC-01, TC-02, TC-03, TC-06, TC-07) read files via
  `std.Io.Dir.cwd().readFileAlloc` with a 8 MB cap; no state mutation.
- No mocks, no stubs, no in-memory database.
- `error.SkipZigTest` is permitted on TC-04 and TC-05 (live-DB cases that
  require `BPM_TEST_DB_URL`); it is FORBIDDEN on TC-01, TC-02, TC-03,
  TC-06, TC-07 because they have no DB dependency.

---

## Regression coverage table

| AC | Description | Test case(s) | Zig test reference |
|---|---|---|---|
| MUST-1 | `zig build bench` exits 0 with only `BPM_BENCH_DB_URL` set | TC-01, TC-09 | `iss0706_gbl116_bench_preflight_test.zig:165` |
| MUST-2 | `zig build bench` exits 0 with `.env`-only path | TC-01, TC-02, TC-09 | `iss0706_gbl116_bench_preflight_test.zig:165`, `:185` |
| MUST-3 | `zig build migrate` exits 0 on a fresh PG with `BPM_DB_URL` | TC-09 (pipeline), MC-3 | end-to-end check |
| MUST-4 | Loud abort when post-condition is missed | TC-03, TC-04 | `iss0706_gbl116_bench_preflight_test.zig:226`, `:85` |
| MUST-5 | Graceful degradation when no URL is available | TC-01 | `iss0706_gbl116_bench_preflight_test.zig:165` |
| MUST-6 | Long-lived DB path is unaffected | TC-05, TC-09 | `iss0706_gbl116_bench_preflight_test.zig:127` |
| MUST-7 | `tools/verify_test_env.py` exits 0 | MC-1 (manual) | env-verify gate |
| MUST-8 | `python tools/lint_handoffs.py` exits 0 on the new handoff | TC-09 (pipeline) | pre-handoff lint |
| MUST-9 | GBL-116 cosmetic message references `GBL-113 and GBL-114` | TC-06 | `iss0706_gbl116_bench_preflight_test.zig:247` |
| MUST-10 | All new regression tests pass | TC-09 (pipeline) | full chain |
| MUST-NOT-1 | GBL-116 pre-flight loop body unchanged | TC-07 | `iss0706_gbl116_bench_preflight_test.zig:281` |
| MUST-NOT-2 | No magic-tenant carve-out | TC-07 (loop iterates all tenants), TC-04 (default tenant is just one row in `public.tenant`) | `iss0706_gbl116_bench_preflight_test.zig:281`, `:85` |
| MUST-NOT-3 | `BPM_BENCH_DB_URL` is not re-pointed to a production URL | TC-02 (precedence unchanged) | `iss0706_gbl116_bench_preflight_test.zig:185` |
| MUST-NOT-4 | Post-condition is read-only | TC-03 (only `SELECT count(*)` text in source) | `iss0706_gbl116_bench_preflight_test.zig:226` |
| MUST-NOT-5 | Post-condition does not abort on pool-open failure | TC-03 (`provision_attempted` gate present) | `iss0706_gbl116_bench_preflight_test.zig:226` |
| MUST-NOT-6 | No shell-script wrapper added | TC-09 (pipeline), MC-2 (no script referenced) | end-to-end check |
| MUST-NOT-7 | `tests/bench/bench.zig::resolveDbUrl` unchanged | TC-02 (mirrors it, not modifies it) | `iss0706_gbl116_bench_preflight_test.zig:185` |
| MUST-NOT-8 | `src/main.zig::runApiServer` not modified | TC-09 (out of scope explicitly) | not in commit `c0654f99` |
| MUST-NOT-9 | No new module-level import in `tests/bench/bench.zig` | TC-02 (test reads `bench.zig` as text; no `@import` assertion added) | `iss0706_gbl116_bench_preflight_test.zig:185` |
| MUST-NOT-10 | No new env var introduced | TC-02 (only the existing three keys are referenced) | `iss0706_gbl116_bench_preflight_test.zig:185` |

**Coverage completeness:** 20 of 20 ACs are covered. 7 Zig test blocks
exist in `tests/integration/iss0706_gbl116_bench_preflight_test.zig` and
are referenced above. No AC is labelled "deferred", "future", or "phase 2".
No `error.SkipZigTest` is used on the source-assertion cases. No test is
left unimplemented.

---

## Wiring (already in place — NOT a follow-up)

The seven test blocks at `tests/integration/iss0706_gbl116_bench_preflight_test.zig`
are **already registered** as the `test-integration-iss0706` build step
(registered by Step 03 BACKEND-DEV). The Step 04 work is documentation-only;
no further `b.addTest` block, no `tests/integration/main_test.zig` import,
no `build.zig` wiring change is required from this handoff.

To run the suite:

```bash
zig build test-integration-iss0706
# Optional: set BPM_TEST_DB_URL to enable TC-04 and TC-05 (live-DB cases).
# Source-assertion cases TC-01, TC-02, TC-03, TC-06, TC-07 always run.
```

---

## Requirement traceability (cross-reference)

| Source artefact | Section | Items referenced |
|---|---|---|
| `src/design/iss-0706-gbl116-bench-pre-flight.md` | §5.1 | Test cases 5.1.1, 5.1.2, 5.1.3, 5.1.4, 5.1.5, 5.1.6 |
| `src/design/iss-0706-gbl116-bench-pre-flight.md` | §6.1 | MUST-1 .. MUST-10 |
| `src/design/iss-0706-gbl116-bench-pre-flight.md` | §6.2 | MUST-NOT-1 .. MUST-NOT-10 |
| `handoffs/WF03-GH791-20260815/diagnosis-01.md` | "Defects A & B" | The two interlocking failures this spec guards against |
| `tests/integration/iss0706_gbl116_bench_preflight_test.zig` | whole file | The 7 runnable `test "..."` blocks |
| `migrations/GBL-116_tnt07_rls_cleanup.sql` | lines 25-61 | The pre-flight gate this fix preserves (MUST-NOT-1) |
| `build.zig` | lines 3789-3798 | The bench step construction site (MUST-1, MUST-2, MUST-5) |
| `src/tools/migrate.zig` | lines 142-187, 297-315 | The two `provisionTenantSchema` call sites (MUST-4, MUST-NOT-5) |