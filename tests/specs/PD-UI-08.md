# Test Spec: PD-UI-08 — Debounced full-text search

**Requirement:** PD-UI-08 — Enhance the definition list search bar with client-side debounce (300 ms) and search result highlighting. The search bar queries `GET /definitions/search?q=` instead of client-side name filter.

**Priority:** MUST
**Test layer:** e2e (Playwright)

---

## Shared preconditions

- A real Keycloak instance is running at `http://localhost:8081` with realm `bpm-default`.
- A test user `admin-user` / `admin-pass` with `PLATFORM_ADMIN` role exists.
- The backend is running at `http://localhost:8080` with a real PostgreSQL database.
- The frontend is served at `http://127.0.0.1:4173` (Vite dev server with `/api` proxy to backend).
- Each test obtains a real JWT via the Keycloak password grant.
- Login is performed by pasting the JWT into the login form.
- After each test, all created definitions are cleaned up via `DELETE /definitions/{id}`.

---

## Test Cases

| TC | Description | Layer | PD-UI-08 AC covered |
|----|-------------|-------|---------------------|
| TC-PDUI08-01 | Search bar is visible on definition list page | e2e | Search bar present |
| TC-PDUI08-02 | Typing in search bar shows results after debounce | e2e | Debounced search returns results |
| TC-PDUI08-03 | Empty search bar shows regular definition list | e2e | Empty query falls back to list |
| TC-PDUI08-04 | No results shows empty state message | e2e | No-results state |
| TC-PDUI08-05 | Search results show highlighted matching text | e2e | Highlighting of matching substrings |
| TC-PDUI08-06 | Search bar does not fire request on every keystroke | e2e | Debounce prevents flooding |

---

### TC-PDUI08-01: Search bar is visible on definition list page

**Given:** The user is logged in and on the definition list page (`/definitions`).
**When:** The page renders.
**Then:** A search input (`getByTestId('definition-search')`) is visible in the filter bar.
**Layer:** e2e

### TC-PDUI08-02: Typing in search bar shows results after debounce

**Given:** A definition with name "Order Approval Flow" exists and the user is on the definition list page.
**When:** The user types "Order" into the search bar and waits for the debounce delay (300 ms) plus API round-trip.
**Then:** The table shows only definitions matching "Order", and results are ranked by relevance.
**Layer:** e2e

### TC-PDUI08-03: Empty search bar shows regular definition list

**Given:** The user is on the definition list page.
**When:** The search bar is empty (default state, or user clears it).
**Then:** The page shows the standard paginated definition list (no search query active).
**Layer:** e2e

### TC-PDUI08-04: No results shows empty state message

**Given:** The user is on the definition list page.
**When:** The user types a query that matches no definitions (e.g., a UUID-like string).
**Then:** The table body shows "No results found for '{query}'".
**Layer:** e2e

### TC-PDUI08-05: Search results show highlighted matching text

**Given:** A definition with name "Quarterly Review" exists.
**When:** The user searches for "Review" and results are displayed.
**Then:** The matching substring "Review" in the definition name/description is wrapped in `<mark>` tags with a yellow background.
**Layer:** e2e

### TC-PDUI08-06: Search bar does not fire request on every keystroke

**Given:** The user is on the definition list page.
**When:** The user types "Or" then "rd" then "er" rapidly (within 300 ms).
**Then:** Only one search request is sent (for the final value "Order"), not three separate requests.
**Layer:** e2e

---

## Coverage Matrix

| PD-UI-08 Acceptance Criterion | Test Cases |
|------------------------------|-----------|
| Search bar present on list page | TC-PDUI08-01 |
| 300 ms debounce before search | TC-PDUI08-02, TC-PDUI08-06 |
| Empty query falls back to list | TC-PDUI08-03 |
| No-results empty state | TC-PDUI08-04 |
| Search result highlighting | TC-PDUI08-05 |
