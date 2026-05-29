# Test Spec: PD-UI-07 — Export/Import buttons

**Requirement:** PD-UI-07 — Add Export button on definition editor page (downloads definition as JSON) and Import button on definition list page (opens file picker, uploads JSON, navigates to imported definition).

**Priority:** MUST
**Test layer:** e2e (Playwright)

---

## Shared preconditions

- A real Keycloak instance is running at `http://localhost:8081` with realm `bpm-default`.
- A test user `admin-user` / `admin-pass` with `PLATFORM_ADMIN` role (granting `PROCESS_DESIGNER` access) exists.
- The backend is running at `http://localhost:8080` with a real PostgreSQL database.
- The frontend is served at `http://127.0.0.1:4173` (Vite dev server with `/api` proxy to backend).
- Each test obtains a real JWT via the Keycloak password grant.
- Login is performed by pasting the JWT into the login form (`getByTestId('login-token-input')`).
- After each test, all created definitions are cleaned up via `DELETE /definitions/{id}`.

---

## Test Cases

| TC | Description | Layer | PD-UI-07 AC covered |
|----|-------------|-------|---------------------|
| TC-PDUI07-01 | Export button is visible on definition editor page | e2e | Export button present |
| TC-PDUI07-02 | Export button downloads a JSON file with definition data | e2e | Export produces downloadable JSON |
| TC-PDUI07-03 | Import button is visible on definition list page | e2e | Import button present |
| TC-PDUI07-04 | Import button opens file picker dialog | e2e | File picker opens |
| TC-PDUI07-05 | Import with valid JSON file creates new definition | e2e | Import creates DRAFT definition |
| TC-PDUI07-06 | Import with invalid JSON shows error dialog | e2e | File parse error handling |
| TC-PDUI07-07 | Import with name+version conflict shows error dialog | e2e | HTTP 409 error handled |

---

### TC-PDUI07-01: Export button is visible on definition editor page

**Given:** A definition exists and the user is logged in.
**When:** The user navigates to the definition editor page (`/definitions/{id}`).
**Then:** An Export button (`getByTestId('btn-export')`) is visible in the toolbar.
**Layer:** e2e

### TC-PDUI07-02: Export button downloads a JSON file with definition data

**Given:** A definition exists and the user is on the definition editor page.
**When:** The user clicks the Export button.
**Then:** A JSON file download is triggered. The downloaded file contains the definition fields including `bpm_export_schema_version`, `name`, `version`, and `graph`.
**Layer:** e2e

### TC-PDUI07-03: Import button is visible on definition list page

**Given:** The user is logged in and on the definition list page (`/definitions`).
**When:** The page renders.
**Then:** An Import button (`getByTestId('btn-import')`) is visible in the filter bar area alongside the "New Definition" button.
**Layer:** e2e

### TC-PDUI07-04: Import button opens file picker dialog

**Given:** The user is logged in and on the definition list page.
**When:** The user clicks the Import button.
**Then:** A file picker dialog opens, accepting `.json` files only.
**Layer:** e2e

### TC-PDUI07-05: Import with valid JSON file creates new definition

**Given:** The user has a valid export JSON file and is on the definition list page.
**When:** The user clicks Import, selects the file, and the import succeeds (HTTP 201).
**Then:** A success toast is shown, the definition list is refreshed, and the user is navigated to the new definition's editor page (`/definitions/{newId}`).
**Layer:** e2e

### TC-PDUI07-06: Import with invalid JSON shows error dialog

**Given:** The user is logged in and on the definition list page.
**When:** The user clicks Import and selects a file that is not valid BPM export JSON (e.g., a `.json` file with `{"foo": "bar"}`).
**Then:** An error dialog is shown with a message indicating the file is invalid.
**Layer:** e2e

### TC-PDUI07-07: Import with name+version conflict shows error dialog

**Given:** A definition with name `N` and version `V` already exists.
**When:** The user imports a JSON file with the same name `N` and version `V`.
**Then:** An error dialog is shown with message indicating that a definition with that name and version already exists (HTTP 409).
**Layer:** e2e

---

## Coverage Matrix

| PD-UI-07 Acceptance Criterion | Test Cases |
|------------------------------|-----------|
| Export button present on editor page | TC-PDUI07-01 |
| Export triggers JSON download | TC-PDUI07-02 |
| Import button present on list page | TC-PDUI07-03 |
| Import opens file picker | TC-PDUI07-04 |
| Import with valid file creates definition | TC-PDUI07-05 |
| Import with invalid file shows error | TC-PDUI07-06 |
| Import with name+version conflict shows error | TC-PDUI07-07 |
