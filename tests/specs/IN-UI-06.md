# Test Spec: IN-UI-06 - Timeline tab

**Requirement:** IN-UI-06 - The instance detail page SHALL include a Timeline tab calling GET /instances/:id/timeline and rendering events as a vertical chronological feed with actor avatars, timestamps, and human-readable descriptions.
**Priority:** MUST
**Test layer:** e2e (Playwright against real backend and real DB)
**Run:** WF02-f3b-inui0508-20260530
**Related test source:** web/tests/e2e/f3-instance-monitoring.e2e.spec.ts

**Implementation mapping:**
- TC-INUI06-01 -> Playwright test `IN-UI-06: timeline tab shows avatar, timestamp, and human-readable description`

**Rework note (WF02-f3b-inui0508-20260530 / Step 03 REWORK 1):**
- Seed setup now waits until `GET /api/v1/instances/:id/timeline` returns `count > 0` for the timeline fixture instance.
- The test now waits for the timeline API response and asserts a non-empty payload before DOM-level avatar/timestamp/description checks.
- Runtime route wiring for `/api/v1/instances/:id/timeline` was fixed in backend routing and timeline first-page rendering state was corrected in the detail page.

**Isolation rule:** Timeline assertions run on a uniquely seeded instance and do not reuse mutable fixtures across tests.

---

## Test Cases

### TC-INUI06-01: Timeline feed renders avatar/timestamp/human-readable description

**Given:** The instance has timeline entries in backend storage
**When:** The user opens the Timeline tab
**Then:** Screen shows timeline entries with actor avatar, timestamp, and description text that is readable (not raw event-type token only)
**Layer:** e2e
**Acceptance criterion mapped:** Vertical timeline feed rendering with avatar/time/description semantics
