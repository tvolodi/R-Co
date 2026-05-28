# Test Report — WF02-f2a-pdui01-04-20260528

**Run ID:** WF02-f2a-pdui01-04-20260528  
**Date:** 2026-05-28  
**Layer:** E2E (Playwright)  
**Test file:** `web/tests/e2e/f2-definition-list.e2e.spec.ts`  
**Requirements:** PD-UI-01, PD-UI-02, PD-UI-03, PD-UI-04  

---

## Summary

| Metric | Value |
|---|---|
| Total tests (suite) | 37 |
| Passed | 24 |
| Failed | 14 |
| — F2 definition list | 13 |
| — OBS-04 timeline (unrelated) | 1 |
| Skipped | 0 |
| Overall verdict | **FAIL** |

---

## F2 Failures

### Failure Pattern A — `POST /definitions` returns 400 `malformed_json`

**Root cause:** The backend `POST /api/v1/definitions` handler (`handleCreate` in `src/api/routes/definitions.zig`) expects a `CreateDefinitionBody` that includes a `graph` field with `nodes` and `edges`, but the test helper `createTestDefinition()` in `web/tests/e2e/f2-definition-list.e2e.spec.ts` sends only `{name, version, description}` without a `graph`. The backend JSON parser rejects the request.

**Affected tests (11):**

| # | Test case | Requirement | Error |
|---|---|---|---|
| 1 | TC-PDUI01-01 | PD-UI-01 | `POST /definitions failed (400): malformed_json` |
| 3 | TC-PDUI01-03 | PD-UI-01 | `POST /definitions failed (400): malformed_json` |
| 5 | TC-PDUI02-02 | PD-UI-02 | `POST /definitions failed (400): malformed_json` |
| 6 | TC-PDUI02-04 | PD-UI-02 | `POST /definitions failed (400): malformed_json` |
| 7 | TC-PDUI02-05 | PD-UI-02 | `POST /definitions failed (400): malformed_json` |
| 8 | TC-PDUI03-01 | PD-UI-03 | `POST /definitions failed (400): malformed_json` |
| 9 | TC-PDUI03-04 | PD-UI-03 | `POST /definitions failed (400): malformed_json` |
| 10 | TC-PDUI04-01 | PD-UI-04 | `POST /definitions failed (400): malformed_json` |
| 11 | TC-PDUI04-02 | PD-UI-04 | `POST /definitions failed (400): malformed_json` |
| 12 | TC-PDUI04-03 | PD-UI-04 | `POST /definitions failed (400): malformed_json` |
| 13 | TC-PDUI04-05 | PD-UI-04 | `POST /definitions failed (400): malformed_json` |

### Failure Pattern B — `filter-bar` element not found on `/definitions` page

**Root cause:** When no test data is created (or creation failed silently), navigating to `/definitions` does not render the `data-testid="filter-bar"` element. The definition list view page may not render, or renders in an unexpected state.

**Affected tests (2):**

| # | Test case | Requirement | Error |
|---|---|---|---|
| 2 | TC-PDUI01-02 | PD-UI-01 | `getByTestId('filter-bar')` not visible (timeout 10s) |
| 4 | TC-PDUI02-01 | PD-UI-02 | `getByTestId('filter-bar')` not visible (timeout 10s) |

---

## Unrelated Failure

| Test | File | Error |
|---|---|---|
| OBS-04 timeline browser flow | `web/tests/e2e/obs04.timeline.e2e.spec.ts:157` | Not applicable to this run |

---

## Environment

| Component | Status |
|---|---|
| Backend (port 8080) | ✅ Running |
| Keycloak (port 8081) | ✅ Running |
| Benchmark environment | ✅ PASS |
| Test user (`admin-user`) | ✅ Authenticates successfully |
| `POST /api/v1/definitions` | ❌ Returns 400 `malformed_json` — requires `graph` field |

---

## Recommendations

1. **Fix test helper `createTestDefinition()`** to include a valid `graph` field with `{nodes: [], edges: []}` (or a minimal valid graph structure).
2. **Investigate `/definitions` page rendering** — determine why the `filter-bar` is not rendered when no definitions exist or when the page loads without pre-seeded data.
