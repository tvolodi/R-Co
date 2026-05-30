# Test Spec: IN-UI-07 - Cancel instance

**Requirement:** IN-UI-07 - A Cancel button (operator+ role only) SHALL show a confirmation dialog and call POST /instances/:id/cancel. The UI SHALL update the status badge immediately (optimistic update with rollback on error).
**Priority:** MUST
**Test layer:** e2e (Playwright against real backend and real DB)
**Run:** WF02-f3b-inui0508-20260530
**Related test source:** web/tests/e2e/f3-instance-monitoring.e2e.spec.ts

**Implementation mapping:**
- TC-INUI07-01 -> Playwright test `IN-UI-07: cancel flow confirms and updates status to CANCELLED`
- TC-INUI07-02 -> Rollback-on-error path noted as conditional in this run (not deterministically induced without introducing forbidden transport mocking)

**Isolation rule:** Cancellation is executed against a dedicated active instance fixture created only for this test flow.

---

## Test Cases

### TC-INUI07-01: Cancel action requires confirmation and updates status

**Given:** Operator-capable user is viewing an ACTIVE instance
**When:** The user clicks Cancel, confirms in dialog, and submits optional reason
**Then:** Screen shows confirmation dialog before API call and then shows CANCELLED status in detail view
**Layer:** e2e
**Acceptance criterion mapped:** Confirmation UX and status update after cancel action

---

### TC-INUI07-02: Rollback-on-error expectation (conditional)

**Given:** Cancel API returns an error for an ACTIVE instance
**When:** The user confirms cancellation
**Then:** Screen restores prior status and shows recoverable error message
**Layer:** e2e (conditional)
**Acceptance criterion mapped:** Rollback on error
**Note:** This run validates success-path optimistic update only. Error-path trigger requires deterministic backend fault injection route not currently available in production-like E2E flow and cannot use mocks per directive T-2.
