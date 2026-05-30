# Test Spec: IN-UI-05 - Event history tab

**Requirement:** IN-UI-05 - The instance detail page SHALL include a History tab that calls GET /instances/:id/history and renders the ordered event log as a filterable table (filter by event type, time range). Raw JSON payload SHALL be expandable inline.
**Priority:** MUST
**Test layer:** e2e (Playwright against real backend and real DB)
**Run:** WF02-f3b-inui0508-20260530
**Related test source:** web/tests/e2e/f3-instance-monitoring.e2e.spec.ts

**Implementation mapping:**
- TC-INUI05-01 -> Playwright test `IN-UI-05: history tab supports filters and expandable raw payload JSON`

**Isolation rule:** Fixtures for this requirement are seeded with unique correlation keys during test setup.

---

## Test Cases

### TC-INUI05-01: History tab filters and payload expansion

**Given:** An instance exists with at least two history event types
**When:** The user opens the History tab, applies event-type and time-range filters, and expands Payload on a row
**Then:** Screen shows only rows matching selected event type/range and displays raw JSON inline for expanded payload
**Layer:** e2e
**Acceptance criterion mapped:** Filterable history table and expandable raw JSON payload
