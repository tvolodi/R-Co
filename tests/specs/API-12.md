# Test Spec: API-12 — Health endpoints

**Requirement:** API-12 — `GET /health/live` SHALL return HTTP 200 if the process is running. `GET /health/ready` SHALL return HTTP 200 only if DB connectivity and all critical subsystems are operational.  
**Priority:** MUST  
**Test layer:** unit, integration

---

## Coverage matrix

| Acceptance criterion | Test case(s) |
|---|---|
| `GET /health/live` returns HTTP 200 with `{ "status": "ok" }`; no auth required | TC-API-12-01, TC-API-12-08, TC-API-12-INT-01 |
| `GET /health/ready` returns HTTP 200 with `{ "status": "ok", "db_latency_ms": N }` when DB-04 passes | TC-API-12-02, TC-API-12-05, TC-API-12-INT-02 |
| `GET /health/ready` returns HTTP 503 with structured failing subsystem body when not ready | TC-API-12-03, TC-API-12-06, TC-API-12-09, TC-API-12-INT-03 |
| Pool exhausted and DB failure variants are explicitly identified | TC-API-12-04, TC-API-12-07, TC-API-12-11, TC-API-12-INT-04 |
| Health endpoints preserve API-09 trace assignment expectations | TC-API-12-10, TC-API-09-01, TC-API-09-03, TC-API-12-INT-05 |
| Health endpoint additions do not regress existing API routes | TC-API-11-03, TC-API-12-08, TC-API-12-INT-06 |
| Health endpoints respond within 1 second budget | TC-API-12-INT-07 |

---

## Unit test cases

Unit tests are implemented in `src/api/routes/health.zig`, `src/api/health/readiness.zig`, and `src/api/routes/openapi.zig`; they run with `zig build test`.

### TC-API-12-01: Liveness handler returns success payload
**Given:** A running process and test allocator  
**When:** `handleLive(allocator)` is invoked  
**Then:** The response is HTTP `200` with exact body `{"status":"ok"}`  
**Layer:** unit  
**Acceptance criterion mapped:** Liveness behavior and payload shape

### TC-API-12-02: Readiness handler returns ready payload when DB-04 and critical checks pass
**Given:** A readiness service using a successful DB-04 health check and successful subsystem checkers  
**When:** `handleReady(allocator, pool, readiness)` is invoked  
**Then:** The response is HTTP `200` with `{"status":"ok","db_latency_ms":N}`  
**Layer:** unit  
**Acceptance criterion mapped:** Readiness success path

### TC-API-12-03: Readiness handler returns degraded payload when not ready
**Given:** A readiness service whose DB check fails with pool exhaustion  
**When:** `handleReady(...)` is invoked  
**Then:** The response is HTTP `503` with `status=degraded` and `failing_subsystems` details  
**Layer:** unit  
**Acceptance criterion mapped:** Structured degraded response

### TC-API-12-04: Pool exhaustion maps to stable failing-subsystem variant
**Given:** `db_pool.PoolError.ExhaustedPool`  
**When:** `mapPoolErrorToFailure(...)` is called  
**Then:** Mapping yields subsystem `database`, code `POOL_EXHAUSTED`, and retryable `true`  
**Layer:** unit  
**Acceptance criterion mapped:** Explicit pool exhaustion variant

### TC-API-12-05: Readiness evaluate returns ready result with DB latency
**Given:** DB-04 success and all critical subsystem checks passing  
**When:** `ReadinessService.evaluate(...)` is executed  
**Then:** Result is `.ready` and includes `db_latency_ms` from DB-04  
**Layer:** unit  
**Acceptance criterion mapped:** DB-04 based readiness success

### TC-API-12-06: Readiness evaluate aggregates subsystem failures
**Given:** DB-04 success and a failing non-DB critical checker  
**When:** `ReadinessService.evaluate(...)` is executed  
**Then:** Result is `.not_ready` with structured failing subsystem list  
**Layer:** unit  
**Acceptance criterion mapped:** Structured subsystem failure reporting

### TC-API-12-07: Readiness evaluate reports pool exhaustion failure variant
**Given:** DB-04 returns `ExhaustedPool`  
**When:** `ReadinessService.evaluate(...)` is executed  
**Then:** Result is `.not_ready` with code `POOL_EXHAUSTED`  
**Layer:** unit  
**Acceptance criterion mapped:** Pool exhaustion degraded path

### TC-API-12-08: Health paths are public in OpenAPI metadata
**Given:** Generated OpenAPI document  
**When:** Security arrays for `/health/live` and `/health/ready` are inspected  
**Then:** Both are empty security arrays (public/no auth)  
**Layer:** unit  
**Acceptance criterion mapped:** No authentication requirement for health endpoints

### TC-API-12-09: Readiness handler reports DB query failure variant
**Given:** A readiness service whose DB-04 check fails with `QueryFailed`  
**When:** `handleReady(...)` is invoked  
**Then:** The response is HTTP `503` and failing subsystem code `DB_QUERY_FAILED`  
**Layer:** unit  
**Acceptance criterion mapped:** Explicit DB failure variant

### TC-API-12-10: Health handlers remain stable with API-09 trace context active
**Given:** API-09 trace context is set for the current request scope  
**When:** `handleLive(...)` and `handleReady(...)` are invoked  
**Then:** Both handlers still return expected API-12 success responses  
**Layer:** unit  
**Acceptance criterion mapped:** Trace assignment compatibility

### TC-API-12-11: Readiness evaluate reports DB connection failure variant
**Given:** DB-04 returns `ConnectionFailed`  
**When:** `ReadinessService.evaluate(...)` is executed  
**Then:** Result is `.not_ready` with code `DB_CONNECTION_FAILED` and stable detail text  
**Layer:** unit  
**Acceptance criterion mapped:** Explicit DB failure variant

---

## Integration test cases (for TEST-RUNNER execution)

### TC-API-12-INT-01: `GET /health/live` returns 200 without Authorization
**Given:** BPM server is running  
**When:** `GET /health/live` is sent without an `Authorization` header  
**Then:** HTTP status is `200`, body equals `{ "status": "ok" }`  
**Layer:** integration  
**Acceptance criterion mapped:** Public liveness endpoint

### TC-API-12-INT-02: `GET /health/ready` returns 200 with `db_latency_ms` when DB is healthy
**Given:** BPM server is running with reachable DB  
**When:** `GET /health/ready` is sent  
**Then:** HTTP status is `200`; body includes `status=ok` and numeric `db_latency_ms`  
**Layer:** integration  
**Acceptance criterion mapped:** DB-04 readiness success at HTTP boundary

### TC-API-12-INT-03: `GET /health/ready` returns structured 503 on readiness failure
**Given:** Readiness is degraded by forcing a failing critical subsystem  
**When:** `GET /health/ready` is sent  
**Then:** HTTP status is `503` and body includes `status=degraded` and non-empty `failing_subsystems`  
**Layer:** integration  
**Acceptance criterion mapped:** Structured degraded response

### TC-API-12-INT-04: Pool exhausted and DB failure variants are distinguishable
**Given:** Two degraded scenarios: exhausted pool and DB connectivity/query failure  
**When:** `GET /health/ready` is sent per scenario  
**Then:** Failing subsystem codes reflect distinct variants (e.g., `POOL_EXHAUSTED`, `DB_CONNECTION_FAILED` or `DB_QUERY_FAILED`)  
**Layer:** integration  
**Acceptance criterion mapped:** Explicit degraded-path variant coverage

### TC-API-12-INT-05: Health requests still receive API-09 trace headers
**Given:** BPM server with trace middleware enabled  
**When:** `GET /health/live` and `GET /health/ready` are sent with and without incoming `X-Trace-Id`  
**Then:** Responses include trace assignment/propagation according to API-09 behavior  
**Layer:** integration  
**Acceptance criterion mapped:** API-09 compatibility for health endpoints

### TC-API-12-INT-06: Existing core API routes remain reachable after health route additions
**Given:** BPM server is running  
**When:** Existing core endpoints (definitions, instances, tasks, openapi) are requested  
**Then:** Existing route matching/availability is unchanged and health routes are also reachable  
**Layer:** integration  
**Acceptance criterion mapped:** No regression of existing API routes

### TC-API-12-INT-07: Health endpoints satisfy the 1-second response budget
**Given:** BPM server in nominal environment  
**When:** `GET /health/live` and `GET /health/ready` are measured over repeated requests  
**Then:** Each response completes in under 1000ms  
**Layer:** integration  
**Acceptance criterion mapped:** API-12 latency constraint
