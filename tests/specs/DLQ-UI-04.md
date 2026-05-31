# Test Spec: DLQ-UI-04 — Discard action

**Requirement:** DLQ-UI-04 — A Discard button (with confirmation) calls POST /dlq/:id/discard. If the item is tied to an instance, the confirmation dialog states that the instance will be cancelled.
**Priority:** MUST
**Test layer:** e2e

## Test Cases

### TC-DLQ-UI-04-E2E-01: Discard action opens confirmation dialog with cancellation warning context
**Given:** a PROCESS_OPERATOR or PLATFORM_ADMIN session with a DLQ row exposing the Discard action
**When:** the user clicks Discard
**Then:** a confirmation dialog opens with the discard warning text; user can cancel and return to the list without mutating state
**Layer:** e2e
**Acceptance criterion mapped:** discard confirmation gate and warning visibility
**Implemented by:** `web/tests/e2e/f6-dlq.e2e.spec.ts` (`TC-DLQ-UI-04-E2E-01`)

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| DLQ-UI-04: discard action requires confirmation | `TC-DLQ-UI-04-E2E-01` |
| DLQ-UI-04: warning copy appears in dialog | `TC-DLQ-UI-04-E2E-01` |

## Execution Notes For TEST-RUNNER

- Test seeds actionable DLQ data through real backend flow before opening the discard dialog (no mocks or manual DB inserts).
- Test requires DLQ API endpoint availability so a row with instance context is available to assert warning copy.
- Test intentionally cancels the dialog to avoid destructive mutation while still proving the confirmation gate.
- Screenshot is captured with the confirmation dialog visible for visual verification.