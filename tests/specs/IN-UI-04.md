# Test Spec: IN-UI-04 - Instance detail view

**Requirement:** IN-UI-04 - Clicking an instance SHALL navigate to a detail page showing current status, definition snapshot info, active tokens (highlighted on a read-only graph), current variable map, and active tasks.
**Priority:** MUST
**Test layer:** e2e (Playwright against real backend and real DB)
**Run:** WF02-f3a-batch1-20260529
**Rework iteration:** 1 (hard-gate remediation)
**Related test source:** web/tests/e2e/f3-instance-monitoring.e2e.spec.ts

**Implementation mapping:**
- TC-INUI04-01 -> Playwright test `TC-INUI04-01: detail page shows required information panels`
- TC-INUI04-02 -> Playwright test `TC-INUI04-02: variables map renders persisted instance state`

**Isolation rule:** Fixtures for this requirement are seeded per test using UUID identifiers and cleaned in `afterEach`.

---

## Test Cases

### TC-INUI04-01: Detail page shows required information panels

**Given:** A started instance exists
**When:** The user opens /instances/{id}
**Then:** Screen shows Instance heading, Definition Snapshot section, Variables section, Active Tasks section, and read-only graph with highlighted active-node state
**Layer:** e2e
**Acceptance criterion mapped:** Required detail-page panels including read-only graph and active tokens

---

### TC-INUI04-02: Variables map is rendered from persisted instance state

**Given:** The instance was started with initial variables
**When:** The detail page loads
**Then:** Variables panel displays JSON values persisted for the instance
**Layer:** e2e
**Acceptance criterion mapped:** Current variable map rendering on detail page
