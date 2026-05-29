# Test Report — WF03-f2a-e2e-fix-20260528

**Run ID:** WF03-f2a-e2e-fix-20260528
**Date:** 2026-05-28
**Layer:** E2E (Playwright)
**Test file:** `web/tests/e2e/f2-definition-list.e2e.spec.ts`
**Requirements:** PD-UI-01, PD-UI-02, PD-UI-03, PD-UI-04
**Commit:** bfcff05
**Branch:** feature/WF03-f2a-e2e-fix-20260528

---

## Summary

| Metric | Value |
|---|---|
| Total tests (F2 suite) | 13 |
| Passed | 7 |
| Failed | 6 |
| Skipped | 0 |
| Overall verdict | **FAIL** |

---

## Passed Tests (7)

| # | Test case | Requirement | Time |
|---|---|---|---|
| 1 | TC-PDUI01-01 — definition list shows definitions from the backend | PD-UI-01 | 1.1s |
| 2 | TC-PDUI01-02 — empty state renders when no definitions exist for search | PD-UI-01 | 1.7s |
| 3 | TC-PDUI02-01 — status filter dropdown shows all four options | PD-UI-02 | 1.1s |
| 4 | TC-PDUI02-04 — status filter selects Draft and shows filtered results | PD-UI-02 | 1.6s |
| 5 | TC-PDUI02-05 — clearing all status filters shows all definitions | PD-UI-02 | 1.8s |
| 6 | TC-PDUI04-01 — "New Definition" button opens create dialog | PD-UI-04 | 814ms |
| 7 | TC-PDUI04-05 — Cancel button dismisses the dialog | PD-UI-04 | 1.6s |

---

## Failed Tests (6)

### Failure 1 — TC-PDUI01-03: search input filters definitions by name (PD-UI-01)

**Error:** `expect(getByTestId('def-name-{id}')).toBeVisible()` failed — element not found.

**Root cause:** After typing `Alpha {uniqueSuffix}` into the search box and waiting for debounce + API round-trip, the search returns no results. Screenshot confirms the page shows "No definitions found" with the search field populated. The search query likely doesn't match the created definition name (e.g., the backend search does an exact/prefix match, not a substring match against "Alpha Flow ...").

**Suggested fix:** Verify the backend search endpoint behavior (substring vs prefix vs exact matching). Adjust the search query or the definition name accordingly.

---

### Failure 2 — TC-PDUI02-02: selecting Draft filter shows only DRAFT definitions (PD-UI-02)

**Error:** `ReferenceError: def is not defined`

**Root cause:** Simple code bug. The test creates a variable named `draftDef` on line 277:
```js
const draftDef = await createTestDefinition(...)
```
but then references `def.id` on line 282:
```js
await expect(page.getByTestId(`def-name-${def.id}`)).toBeVisible()
```
The variable name should be `draftDef`, not `def`.

**Suggested fix:** Change `def.id` → `draftDef.id` on line 282.

---

### Failure 3 — TC-PDUI03-01: clicking definition name expands version history row (PD-UI-03)

**Error:** `expect(getByTestId('version-history-row')).toBeVisible()` failed after 10s timeout.

**Root cause:** Clicking the definition name button (`def-name-{id}`) navigates to the definition editor page (`/definitions/{id}`) instead of expanding a version history row inline. Screenshot shows the page navigated to "Edit: Version Flow ..." with a JSON graph editor. The `version-history-row` element does not exist on that page. The definition list view renders names as `<a>`/`<Link>` navigation elements, not as expandable row toggles.

**Suggested fix:** Either (a) change the UI to support inline expand/collapse for version history, or (b) update the test to verify navigation to the definition detail page instead of inline expansion.

---

### Failure 4 — TC-PDUI03-04: clicking the same name again collapses the version history (PD-UI-03)

**Error:** `expect(getByTestId('version-history-row')).toBeVisible()` failed — element not found.

**Root cause:** Same as Failure 3 — clicking the definition name navigates to the editor page rather than expanding inline. The expand/collapse model doesn't exist in the current UI implementation.

**Suggested fix:** Same as Failure 3.

---

### Failure 5 — TC-PDUI04-02: dialog validates required name field (PD-UI-04)

**Error:** Test timeout (30s) — `locator.click` on `create-submit` button failed because the element is `disabled`.

**Root cause:** The "Create" submit button has `disabled` attribute when the name field is empty (frontend validation). Playwright cannot click a disabled element. The test expects a validation error message to appear after clicking submit, but the submit button is blocked by the HTML `disabled` attribute before any submission attempt.

**Suggested fix:** Either (a) remove the `disabled` attribute from the submit button and rely on backend or inline validation, or (b) update the test to trigger validation via a different mechanism (e.g., blur the name input field) and assert the error message appears without clicking submit.

---

### Failure 6 — TC-PDUI04-03: creating a definition succeeds (PD-UI-04)

**Error:** `page.waitForURL(/\/definitions\/(?!new$)([0-9a-f-]+)/)` timed out after 15s.

**Root cause:** The backend `POST /api/v1/definitions` returned an error — the screenshot shows the "Create New Definition" dialog still open with a red error message "Failed to create definition". The request likely fails because the frontend sends `graph` with `nodes` and `edges` (from the form), but the backend rejects it for a different reason (e.g., validation of the graph structure, missing fields, or duplicate name).

**Suggested fix:** Check the backend API logs to determine why `POST /definitions` returns an error. Fix the backend handler or the frontend request payload accordingly.

---

## Environment

| Component | Status |
|---|---|
| Backend (port 8080) | ✅ Running — health check OK |
| Vite dev server (port 4173) | ✅ Running |
| Keycloak (port 8081) | ✅ Available |
| Benchmark environment | ✅ PASS |

---

## Recommendations

1. **Fix TC-PDUI02-02** — rename `def` → `draftDef` (trivial code fix).
2. **Fix TC-PDUI04-02** — adjust test to handle disabled submit button or update form validation UX.
3. **Fix TC-PDUI04-03** — investigate backend `POST /definitions` failure.
4. **Fix TC-PDUI03-01/03-04** — align the definition list navigation behavior with the expand/collapse test model.
5. **Fix TC-PDUI01-03** — verify search endpoint matching behavior.
