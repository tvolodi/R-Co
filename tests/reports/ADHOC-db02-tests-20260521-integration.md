# Integration Test Report — ADHOC-db02-tests-20260521

**Run ID:** ADHOC-db02-tests-20260521  
**Step:** 02 — TEST-RUNNER  
**Date:** 2026-05-21  
**Handoff ID:** 11200002-2605-4000-8001-202605210011

---

## Summary

| Metric | Value |
|---|---|
| Total tests | 19 |
| Passed | 19 |
| Failed | 0 |
| Exit code (`zig build test`) | 0 |
| Exit code (`zig build test-integration`) | 0 |

**Verdict: PASS**

---

## New tests

| Test ID | Name | Result |
|---|---|---|
| TC-DB-02-03 | pool exhaustion returns ExhaustedPool; release restores availability | **PASS** |
| TC-DB-02-04 | invalid pool_size returns InvalidPoolSize; boundary values succeed | **PASS** |

---

## All 19 integration tests

All 17 previously-passing tests continue to pass. No regressions.

```
Build Summary: 3/3 steps succeeded; 19/19 tests passed
+- run test 19 pass (19 total) 4s MaxRSS:22M
```

---

## Blocker resolved during run

**Problem:** TC-DB-02-04 failed on first run (18/19 pass).

**Root cause:** PostgreSQL default `max_connections = 100`. TC-DB-02-04 creates a `pool_size = 200` pool to verify the upper boundary. Once the connection limit is exceeded, PostgreSQL sends an `ErrorResponse` during the startup phase; `vendor/pg/pg.zig:454` maps any `'E'` message during auth to `PgError.AuthenticationFailed`, which `pool.zig` converts to `PoolError.ConnectionFailed`. The test expected `try Pool.init(...)` to succeed, so it failed.

**Fix applied:** Added `command: postgres -c max_connections=250` to the `db_test` service in `docker-compose.yml`. Container was recreated. TC-DB-02-04 passed on the next run.

**Files changed:** `docker-compose.yml`
