# Test Spec: IN-UI-02 - Status and definition filters

**Requirement:** IN-UI-02 - The board SHALL support filtering by status (multi-select) and definition name (typeahead). Filters are URL-persisted.
**Priority:** MUST
**Test layer:** e2e (Playwright against real backend and real DB)
**Run:** WF02-f3a-batch1-20260529
**Rework iteration:** 1 (hard-gate remediation)
**Related test source:** web/tests/e2e/f3-instance-monitoring.e2e.spec.ts

**Implementation mapping:**
- TC-INUI02-01 -> Playwright test `TC-INUI02-01: status filter toggles and persists in URL`
- TC-INUI02-02 -> Playwright test `TC-INUI02-02: definition typeahead persists in URL and after reload`

**Isolation rule:** Fixtures for this requirement are seeded per test using UUID identifiers and cleaned in `afterEach`.

---

## Test Cases

### TC-INUI02-01: Status filter toggles and persists in URL

**Given:** The instance board is open
**When:** The user checks ACTIVE status in the status filter set
**Then:** Screen shows ACTIVE filter selected and URL contains status=ACTIVE
**Layer:** e2e
**Acceptance criterion mapped:** Status multi-select filter behavior and URL persistence

---

### TC-INUI02-02: Definition typeahead resolves to definition ID and persists across reload

**Given:** A known active definition exists
**When:** The user enters the definition name in the typeahead filter and leaves the field
**Then:** URL contains definitionName and definitionId; after page reload, the filter values remain selected and visible
**Layer:** e2e
**Acceptance criterion mapped:** Definition-name typeahead filter behavior and URL-persisted state
