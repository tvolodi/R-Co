# Test Spec: IN-UI-08 - Auto-refresh

**Requirement:** IN-UI-08 - The instance board and detail pages SHALL poll for updates every 10 seconds (configurable). An indicator SHALL show the last-refreshed time and a manual refresh button.
**Priority:** SHOULD
**Test layer:** e2e (Playwright against real backend and real DB)
**Run:** WF02-f3b-inui0508-20260530
**Related test source:** web/tests/e2e/f3-instance-monitoring.e2e.spec.ts

**Implementation mapping:**
- TC-INUI08-01 -> Playwright test `IN-UI-08: board/detail refresh indicator and manual refresh are visible and functional`

**Isolation rule:** Uses seeded instances and assertion on UI refresh labels only, with no mocked timers or intercepted requests.

---

## Test Cases

### TC-INUI08-01: Board and detail expose refresh indicator and manual refresh trigger

**Given:** User is logged in and can open instance board/detail pages
**When:** The user observes Last refreshed label, waits for auto-update on detail, and clicks Refresh on board/detail
**Then:** Screen shows Last refreshed indicator on both pages and label value updates after manual refresh (and auto-refresh interval on detail)
**Layer:** e2e
**Acceptance criterion mapped:** Polling feedback indicator plus explicit refresh trigger
