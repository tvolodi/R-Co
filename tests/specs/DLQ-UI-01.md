# Test Spec: DLQ-UI-01 — DLQ list

**Requirement:** DLQ-UI-01 — A paginated table of dead letter items with columns: source type badge, related instance (link), failure reason (truncated), retry count, created time, status.
**Priority:** MUST
**Test layer:** e2e

## Test Cases

### TC-DLQ-UI-01-E2E-01: DLQ table renders all required columns and populated rows
**Given:** a PROCESS_OPERATOR or PLATFORM_ADMIN session with at least one DLQ item in the backend
**When:** the user navigates to the DLQ page (`/dlq`)
**Then:** the screen shows the DLQ table with Source, Instance, Reason, Retry count, Created, and Status columns and at least one item row
**Layer:** e2e
**Acceptance criterion mapped:** required DLQ list columns and row rendering
**Implemented by:** `web/tests/e2e/f6-dlq.e2e.spec.ts` (`TC-DLQ-UI-01-E2E-01`)

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| DLQ-UI-01: list columns are present | `TC-DLQ-UI-01-E2E-01` |
| DLQ-UI-01: rows are rendered from real backend data | `TC-DLQ-UI-01-E2E-01` |

## Execution Notes For TEST-RUNNER

- Test seeds actionable DLQ data through real backend flow before assertions: create definition -> start instance -> complete task -> trigger failing service-task transition that should write DLQ.
- Test requires DLQ list API to be reachable for UI data loading (`GET /api/v1/dlq` from frontend, backend-mapped route must exist).
- Test uses real backend and Keycloak readiness checks before browser actions.
- Test captures a screenshot after table render for visual confirmation.
- If no DLQ rows exist, the test fails explicitly with a fixture-precondition error (no deferred coverage).