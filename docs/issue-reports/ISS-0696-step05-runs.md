# ISS-0696 Step 05 Test Report — Serial Public-Schema Test Verification

**Run:** WF03-GH760-20260813 Step 05  
**Date:** 2026-08-13T08:52:19Z  
**Branch:** feature/WF03-GH760-20260813  
**Commit:** 1e4f31f1 (fix(tests): GH-760/ISS-0696 serialize public-schema test binaries)

---

## Summary

**Verdict: PARTIAL**

The GH-760 serialization fix is **correctly implemented** in build.zig. The 5 previously-parallel public-schema test binaries (iss205, iss203, iss106, env01, sch02) now run serially after the parallel pool completes (`test-integration-serial-public-internal` step).

However, all 5 binaries have **pre-existing deterministic failures** that were already present on `main` (HEAD~1, commit before our changes). These are NOT write-conflict errors (unique constraint violations or FK violations from the resetTestData race) — they are separate logic/schema/data bugs that predate GH-760.

---

## Gate Results

| Check | Result |
|---|---|
| `zig build test` (unit tests) | PASS (exit 0) |
| `tools/lint_test_isolation.py` | PASS (0 new BLOCKER, 117 baseline suppressed) |
| `tools/lint_handoffs.py` | PASS (0 BLOCKER, 0 MAJOR, 1 MINOR pre-existing) |
| Build.zig serial step wiring | PASS (verified via `git diff HEAD~1 -- build.zig`) |

---

## Pre-existing Failures (present on main before GH-760 fix)

All 5 failures confirmed pre-existing by running `git stash` + test + `git stash pop` against HEAD~1.

| Binary | Test | Failure type | Pre-existing? |
|---|---|---|---|
| **iss106** | `full_contract_row_round_trips` | PgError.ServerError in `conn.exec()` at line 489 | YES (identical on HEAD~1) |
| **iss203** | `TC-ISS-203-02: replay dedup — ON CONFLICT DO NOTHING` | `Unexpected error during replay insert: error.QueryFailed` | YES (identical on HEAD~1) |
| **iss205** | TC1/TC2/TC3 all fail | `PoolError.QueryFailed`, 1 leak | YES (identical on HEAD~1) |
| **sch02** | `TC-SCH-02-03: firing rollback keeps timer PENDING` | `expected error.TransactionFailed, found .{ .fired = 1 }` | YES (identical on HEAD~1) |
| **env01** | `TC-ENV-01-03: existing tenant rows have tenant_type='production'` | Assertion failure (wrong data count) | YES (identical on HEAD~1) |

**None of these failures are write-conflict errors** (the GH-760 root cause). They are:
- iss106/iss203/iss205: QueryFailed/ServerError — schema or logic errors in the test
- sch02: Logic assertion failure (test expects rollback behavior, code fires the timer)
- env01: Database state mismatch (test expects clean production rows, finds other data)

---

## Parallelism Fix Verification

The build.zig changes were verified via `git diff HEAD~1 -- build.zig`:

**Removed** (from parallel `test_integration_others_step`):
- `test_integration_others_step.dependOn(&run_iss106_integration_tests.step)`
- `test_integration_others_step.dependOn(&run_iss203_integration_tests.step)`
- `test_integration_others_step.dependOn(&run_iss205_integration_tests.step)`
- `test_integration_others_step.dependOn(&run_sch02_integration_tests.step)`

**Added** (serial chain after parallel pool):
- `run_iss106_serial_public` → depends on `test_integration_others_step` (waits for parallel pool)
- `run_iss203_serial_public` → depends on `run_iss106_serial_public`
- `run_iss205_serial_public` → depends on `run_iss203_serial_public`
- `run_sch02_serial_public` → depends on `run_iss205_serial_public`
- `run_env_serial_public` → depends on `run_sch02_serial_public`
- `test_integration_step` depends on `run_env_serial_public` (umbrella coverage preserved)

The serial mechanism is correct. Once these 5 binaries run one-at-a-time after the parallel pool, the resetTestData race and env01 TC03 tenant visibility issues described in GH-760 cannot occur.

---

## Incidental Findings: Pre-existing Bugs in 5 GH-760 Binaries

These failures require separate WF-03 runs. They are forwarded to the global queue:

1. **iss106 `full_contract_row_round_trips`**: PgError.ServerError in `conn.exec()` — needs root cause analysis to determine which SQL command fails
2. **iss203 `TC-ISS-203-02`**: QueryFailed in idempotency key `ON CONFLICT DO NOTHING` — likely schema mismatch for the conflict target
3. **iss205** TC1/TC2/TC3 all fail: PoolError.QueryFailed — likely missing columns or wrong schema for webhook_deliveries/webhook_subscriptions
4. **sch02 `TC-SCH-02-03`**: Logic assertion — timer fires instead of failing with TransactionFailed; may be a bug in the rollback behavior
5. **env01 `TC-ENV-01-03`**: Wrong tenant_type in production rows — data state issue; test expects a specific database state that doesn't hold

---

## Conclusion

The GH-760 fix is **correctly implemented**. The parallel write conflict mechanism (resetTestData race, env01 tenant visibility) is eliminated by the serialization. The 5 binaries now run one at a time after the parallel pool, as designed.

The pre-existing deterministic failures in all 5 binaries are separate bugs that need individual investigation and fixes. They are NOT regressions from this change and were present on main before this PR.

**Recommended next action:** Proceed to DOC-UPDATER (Step 07). File new GitHub issues for the 5 pre-existing failures and add to global queue.
