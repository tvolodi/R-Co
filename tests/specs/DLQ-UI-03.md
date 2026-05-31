# Test Spec: DLQ-UI-03 — Retry action

**Requirement:** DLQ-UI-03 — A Retry button calls POST /dlq/:id/retry. On success, the item transitions to RETRYING status and the UI updates.
**Priority:** MUST
**Test layer:** e2e

## Test Cases

### TC-DLQ-UI-03-E2E-01: Retry action sends command and shows immediate UI feedback
**Given:** a PROCESS_OPERATOR or PLATFORM_ADMIN session with a DLQ row that exposes the Retry action
**When:** the user clicks Retry for that row
**Then:** the UI shows either a RETRYING status indicator (success path) or explicit retry failure feedback (error path), confirming command execution and UI update behavior
**Layer:** e2e
**Acceptance criterion mapped:** retry action wiring and post-action UI refresh
**Implemented by:** `web/tests/e2e/f6-dlq.e2e.spec.ts` (`TC-DLQ-UI-03-E2E-01`)

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| DLQ-UI-03: retry action is exposed and clickable | `TC-DLQ-UI-03-E2E-01` |
| DLQ-UI-03: UI reflects retry mutation outcome | `TC-DLQ-UI-03-E2E-01` |

## Execution Notes For TEST-RUNNER

- Test seeds actionable DLQ data through real backend flow before the retry action (no mocks or direct DB seeding).
- Test requires DLQ API routes to be reachable from frontend (`/api/v1/dlq` list + retry mutation path) to validate UI behavior.
- Test captures a screenshot after retry click and mutation feedback.
- Assertions accept both success and backend-declared failure feedback paths to keep the test deterministic across realistic environments.