# Test Spec: IN-UI-01 - Instance list

**Requirement:** IN-UI-01 - The instance board SHALL display a paginated table of instances with columns: instance ID (truncated), definition name + version, status badge, correlation key, start time, last updated.
**Priority:** MUST
**Test layer:** e2e (Playwright against real backend and real DB)
**Run:** WF02-f3a-batch1-20260529
**Rework iteration:** 1 (hard-gate remediation)
**Related test source:** web/tests/e2e/f3-instance-monitoring.e2e.spec.ts

**Implementation mapping:**
- TC-INUI01-01 -> Playwright test `TC-INUI01-01: board renders required columns and truncated ID`
- TC-INUI01-02 -> Playwright test `TC-INUI01-02: pagination advances using next cursor`

**Isolation rule:** Fixtures for this requirement are seeded per test using UUID identifiers and cleaned in `afterEach`.

---

## Test Cases

### TC-INUI01-01: Instance board renders required columns and truncated ID

**Given:** An authenticated user and seeded instances exist in the system
**When:** The user opens /instances with pagination enabled
**Then:** Screen shows a paginated instance table with columns Instance ID, Definition, Status, Correlation Key, Started, Last Updated; the Instance ID cell is rendered in truncated form (... suffix); status is shown as a badge-style colored label
**Layer:** e2e
**Acceptance criterion mapped:** Required table columns and truncated identifier rendering

---

### TC-INUI01-02: Pagination advances using next cursor

**Given:** At least two instances exist and page size is set to 1
**When:** The user clicks Next page
**Then:** Screen shows the next page of rows and URL includes cursor query state
**Layer:** e2e
**Acceptance criterion mapped:** Paginated table behavior
