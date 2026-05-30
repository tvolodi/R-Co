# Test Spec: ADM-UI-09 — Health dashboard

**Requirement:** ADM-UI-09 — The Admin section includes a Health page that displays `GET /health/ready` data in a readable dashboard (database connectivity, DB query latency, scheduler status, uptime) and auto-refreshes every 15 seconds.
**Priority:** MUST
**Test layer:** integration, e2e

## Test Cases

### TC-ADM-UI-09-01: health dashboard renders readiness cards and refresh behavior
**Given:** a PLATFORM_ADMIN session against a running backend
**When:** the admin opens `/admin/health` and triggers a manual refresh
**Then:** the page shows readiness status, database and scheduler cards, DB query latency and uptime fields, a visible refresh indicator, and repeated `GET /health/ready` calls including the 15-second polling cycle
**Layer:** e2e
**Acceptance criterion mapped:** health card layout, readiness data rendering, visible refresh indicator, 15-second auto-refresh polling
**Implemented by:** `tests/integration/adm_ui_09_health_test.zig` (`TC-ADM-UI-09-INT-01`) and `web/tests/e2e/f5-admin-observability.e2e.spec.ts` (`TC-ADM-UI-09-01`)

### TC-ADM-UI-09-INT-01: readiness endpoint returns dashboard data used by the health page
**Given:** a real PostgreSQL-backed test environment with `BPM_TEST_DB_URL`
**When:** the test invokes the readiness handler through the real pool
**Then:** the response returns HTTP 200 with readiness status and `db_latency_ms` present in the body
**Layer:** integration
**Acceptance criterion mapped:** readiness data source for the admin health dashboard
**Implemented by:** `tests/integration/adm_ui_09_health_test.zig` (`TC-ADM-UI-09-INT-01`)

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| ADM-UI-09: health view shows readiness status and subsystem cards | `TC-ADM-UI-09-01` |
| ADM-UI-09: DB query latency and uptime are visible | `TC-ADM-UI-09-01` |
| ADM-UI-09: visible refresh indicator appears during refresh | `TC-ADM-UI-09-01` |
| ADM-UI-09: page auto-refreshes every 15 seconds | `TC-ADM-UI-09-01` |
| ADM-UI-09: readiness data source returns HTTP 200 and latency payload | `TC-ADM-UI-09-INT-01` |

## Execution Notes For TEST-RUNNER

- Runs against the real backend (`/health/ready`) with no HTTP mocking.
- Verifies repeated readiness requests via captured network responses.
- Captures screenshots for the loaded dashboard and refresh state.
