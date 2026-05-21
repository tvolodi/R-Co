---
id: API-12
title: Health endpoints
stage: 4
priority: MUST
status: VALIDATED
---

# API-12 — Health endpoints `[MUST]`

> `GET /health/live` SHALL return HTTP 200 if the process is running. `GET /health/ready` SHALL return HTTP 200 only if DB connectivity and all critical subsystems are operational.

**Acceptance Criteria:**
- `GET /health/live` returns HTTP 200 with `{ "status": "ok" }` if the process is running. No auth required.
- `GET /health/ready` returns HTTP 200 with `{ "status": "ok", "db_latency_ms": N }` if the database is reachable and all critical subsystems are operational. Returns HTTP 503 with a structured body identifying the failing subsystem if not ready. No auth required.
- `GET /health/ready` MUST call DB-04 to verify database connectivity.
- Both endpoints MUST respond within 1 second.
- Health endpoints MUST NOT require authentication (used by load balancers and container orchestrators).

**See:** DB-04 (database health check function), API-09 (trace ID still assigned to health requests)

**Edge cases:**
- `GET /health/live` called during startup before DB connection: returns HTTP 200 (process is running; readiness is separate).
- `GET /health/ready` with pool exhausted: returns HTTP 503 identifying "database pool exhausted".
