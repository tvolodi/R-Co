# Test Spec: DLQ-UI-02 — DLQ item detail

**Requirement:** DLQ-UI-02 — Clicking a DLQ item opens a detail panel showing the full context JSON, full failure reason, retry history, and the source event/timer that failed.
**Priority:** MUST
**Test layer:** e2e

## Test Cases

### TC-DLQ-UI-02-E2E-01: Selecting a DLQ row opens detail panel with full diagnostic content
**Given:** a PROCESS_OPERATOR or PLATFORM_ADMIN session and at least one DLQ entry in the list
**When:** the user clicks the Details action for a DLQ row
**Then:** the detail panel appears and includes sections for Full failure reason, Retry history, Context JSON, and Source payload
**Layer:** e2e
**Acceptance criterion mapped:** DLQ detail panel completeness
**Implemented by:** `web/tests/e2e/f6-dlq.e2e.spec.ts` (`TC-DLQ-UI-02-E2E-01`)

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| DLQ-UI-02: detail panel opens from row action | `TC-DLQ-UI-02-E2E-01` |
| DLQ-UI-02: full reason + retry history visible | `TC-DLQ-UI-02-E2E-01` |
| DLQ-UI-02: context/source payload visible | `TC-DLQ-UI-02-E2E-01` |

## Execution Notes For TEST-RUNNER

- Test seeds actionable DLQ data through real backend flow before UI navigation (definition/instance/task path, no mocks).
- Test requires DLQ list API endpoint availability so details can be opened from an actual row.
- Test captures a screenshot after opening the detail panel.
- Assertions target user-facing section labels to verify required detail payload visibility.