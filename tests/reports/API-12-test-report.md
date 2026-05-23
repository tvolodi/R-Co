# Test Report — API-12 (Health endpoints)

**Date:** 2026-05-23  
**Run ID:** WF02-api12-20260523  
**Handoff:** a1200004-2605-4000-8012-202605231426  
**Agent:** TEST-RUNNER  
**Run timestamp:** 2026-05-23T14:28:34.290648Z  
**Overall Verdict:** PASS

---

## 1. Required Test Execution

Command: `zig build test`  
Exit code: **0**

This satisfies the required execution in the handoff task.

---

## 2. API-12 Acceptance Criteria Validation

Validation source: implemented test cases in `src/api/routes/health.zig`, `src/api/health/readiness.zig`, and `src/api/routes/openapi.zig`, executed via `zig build test`.

| Acceptance criterion | Evidence test(s) | Result |
|---|---|---|
| `GET /health/live` returns HTTP 200 with `{ "status": "ok" }`; no auth required | `TC-API-12-01`, `TC-API-12-08` | PASS |
| `GET /health/ready` returns HTTP 200 with `{ "status": "ok", "db_latency_ms": N }` when DB checks pass | `TC-API-12-02`, `TC-API-12-05` | PASS |
| `GET /health/ready` returns HTTP 503 with structured failing-subsystem body on readiness failure | `TC-API-12-03`, `TC-API-12-06` | PASS |
| Degraded variants explicitly include pool exhausted and DB failure paths | `TC-API-12-04`, `TC-API-12-07`, `TC-API-12-09`, `TC-API-12-11` | PASS |
| Health endpoints maintain API-09 trace compatibility expectations | `TC-API-12-10` | PASS |

---

## 3. Test Case Results

| Test ID | Name | Result |
|---|---|---|
| TC-API-12-01 | handleLive returns HTTP 200 with status ok | PASS |
| TC-API-12-02 | handleReady returns HTTP 200 with db latency when ready | PASS |
| TC-API-12-03 | handleReady returns HTTP 503 with failing subsystem details | PASS |
| TC-API-12-04 | mapPoolErrorToFailure maps exhausted pool to POOL_EXHAUSTED | PASS |
| TC-API-12-05 | evaluate returns ready when DB and critical checkers pass | PASS |
| TC-API-12-06 | evaluate returns not_ready with aggregated subsystem failures | PASS |
| TC-API-12-07 | evaluate returns not_ready when DB-04 reports pool exhausted | PASS |
| TC-API-12-08 | health paths are public in OpenAPI security metadata | PASS |
| TC-API-12-09 | handleReady returns HTTP 503 when DB-04 query health check fails | PASS |
| TC-API-12-10 | health handlers remain stable with API-09 trace context set | PASS |
| TC-API-12-11 | evaluate returns not_ready when DB-04 reports connection failure | PASS |

Summary: **11 passed, 0 failed, 0 skipped** for API-12 targeted tests.

---

## 4. Issues

No BLOCKER/MAJOR/MINOR issues found for API-12.

---

## 5. Artifacts

- `tests/reports/API-12-test-report.md` (this report)
