# Test Spec: IN-UI-03 - Start instance

**Requirement:** IN-UI-03 - A Start Instance button SHALL open a form where the user selects a definition (by name, active version auto-selected), enters an optional correlation key, and provides an initial variables JSON object (with a JSON editor widget).
**Priority:** MUST
**Test layer:** e2e (Playwright against real backend and real DB)
**Run:** WF02-f3a-batch1-20260529
**Rework iteration:** 1 (hard-gate remediation)
**Related test source:** web/tests/e2e/f3-instance-monitoring.e2e.spec.ts

**Implementation mapping:**
- TC-INUI03-01 -> Playwright test `TC-INUI03-01: start dialog exposes required fields`
- TC-INUI03-02 -> Playwright test `TC-INUI03-02: submitting valid start form navigates to instance detail`

**Isolation rule:** Fixtures for this requirement are seeded per test using UUID identifiers and cleaned in `afterEach`.

---

## Test Cases

### TC-INUI03-01: Start dialog exposes all required fields

**Given:** The instance board is open for an authorized user
**When:** The user clicks Start Instance
**Then:** Screen shows start dialog with definition-name input, active-version auto-selected field, optional correlation-key input, and JSON variables editor
**Layer:** e2e
**Acceptance criterion mapped:** Start form structure and required controls

---

### TC-INUI03-02: Submitting valid start form navigates to instance detail

**Given:** Start dialog is open with a valid active definition name
**When:** The user fills optional correlation key and valid JSON variables, then submits
**Then:** Screen navigates to /instances/{id} and displays instance detail heading
**Layer:** e2e
**Acceptance criterion mapped:** Start-instance action through UI with real API-backed instance creation
